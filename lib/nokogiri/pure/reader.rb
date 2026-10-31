# frozen_string_literal: true

require "uri"

module Nokogiri
  module Pure
    # Pull cursor for XML::Reader.
    #
    # libxml reports start tags before the rest of the element arrives, and it
    # raises on the first fatal error. This cursor follows that shape. It reads
    # an IO in chunks so a pipe can yield the first element before EOF.
    class ReaderCursor
      XML_NS = "http://www.w3.org/XML/1998/namespace"
      CHUNK = 4096

      # Reader node types. xml/reader.rb defines the same numbers later.
      NONE = 0
      ELEMENT = 1
      TEXT = 3
      CDATA = 4
      ENTITY_REFERENCE = 5
      PI = 7
      COMMENT = 8
      DOCUMENT_TYPE = 10
      SIGNIFICANT_WHITESPACE = 14
      END_ELEMENT = 15

      def initialize(source:, url:, encoding:, errors:, io:, options: 0, error_owner: nil)
        @url = url&.to_s
        @constructor_encoding = encoding&.to_s
        @errors = errors
        @error_owner = error_owner
        @options = options.to_i
        @io = io ? source : nil
        @buffer = io ? "".b : source.to_s.b
        @eof = !io
        @pos = 0
        @line = 1
        @column = 1
        @pending = []
        @current = nil
        @started = false
        @prologue_done = false
        @failed = nil
        @state = 0
        @version = nil
        @declared_encoding = nil
        @entities = {}
        @entity_base = @url
        @expansion_depth = 0
        @expansion_limits = []
        @stack = []
        @scopes = [{"xml" => XML_NS}]
        @default_ns = [nil]
        @lang_stack = [nil]
        @base_stack = [@url]
        @seen_element = false
        @seen_doctype = false
        # libxml2 reads the first chunk when it makes the reader.
        fill_chunk if io
      end

      def read
        raise XML::SyntaxError, @failed.to_s if @failed
        return if @state == 3

        if @pending.any?
          @current = @pending.shift
          @started = true
          @state = 1
          return :ok
        end

        event = pull_event
        if event.nil?
          @state = 3
          @started = true
          return
        end

        @current = event
        @started = true
        @state = 1
        :ok
      end

      attr_reader :state

      def node_type
        @current ? @current[:type] : NONE
      end

      def name
        enc(field(:name))
      end

      def local_name
        enc(field(:local_name))
      end

      def prefix
        enc(field(:prefix))
      end

      def namespace_uri
        enc(field(:namespace_uri))
      end

      def value
        text = field(:value)
        text.nil? ? nil : enc(text)
      end

      def value?
        return false unless @current

        [TEXT, CDATA, COMMENT, PI, SIGNIFICANT_WHITESPACE].include?(@current[:type])
      end

      def depth
        @current ? @current[:depth] : 0
      end

      def lang
        enc(field(:lang))
      end

      def base_uri
        enc(field(:base))
      end

      def xml_version
        return unless @started

        enc(@version || "1.0")
      end

      def encoding
        label = encoding_label
        return if label.nil?

        label.dup
      end

      def empty_element?
        !!(@current && @current[:type] == ELEMENT && @current[:empty])
      end

      def default?
        false
      end

      def attributes?
        frame = element_frame
        return false unless frame

        frame[:items].any?
      end

      def attribute_count
        return 0 unless @current && @current[:type] == ELEMENT

        @current[:frame][:items].length
      end

      def attribute(name)
        return if name.nil?

        frame = element_frame
        return unless frame

        if name == "xmlns"
          item = frame[:items].find { |entry| entry[:ns] && entry[:prefix].nil? }
          return item ? enc(item[:href]) : nil
        end

        if name.start_with?("xmlns:")
          prefix = name.split(":", 2).last
          item = frame[:items].find { |entry| entry[:ns] && entry[:prefix] == prefix }
          return item ? enc(item[:href]) : nil
        end

        item = frame[:items].find { |entry| !entry[:ns] && entry[:qname] == name }
        item ? enc(item[:value]) : nil
      end

      def attribute_at(index)
        return if index.nil?

        frame = element_frame
        return unless frame

        namespaces = frame[:items].select { |entry| entry[:ns] }
        attributes = frame[:items].reject { |entry| entry[:ns] }
        values = namespaces.map { |entry| entry[:href] } + attributes.map { |entry| entry[:value] }
        enc(values[index.to_i])
      end

      def attribute_hash
        frame = element_frame
        return {} unless frame
        return {} if frame[:items].none?

        expand_frame(frame)
        hash = {}
        frame[:items].each do |entry|
          next if entry[:ns]

          hash[enc(entry[:local])] = enc(entry[:value])
        end
        hash
      end

      def namespaces
        frame = element_frame
        return {} unless frame
        return {} if frame[:items].none?

        expand_frame(frame)
        hash = {}
        frame[:items].each do |entry|
          next unless entry[:ns]

          hash[enc(entry[:key])] = enc(entry[:href])
        end
        hash
      end

      def outer_xml
        return unless @current

        case @current[:type]
        when END_ELEMENT
          enc(serialize_empty(@current[:frame]))
        when ELEMENT
          frame = @current[:frame]
          expand_frame(frame)
          enc(slice_bytes(frame[:start_offset], frame[:close_offset]))
        when DOCUMENT_TYPE
          enc("")
        else
          enc(@current[:raw].to_s)
        end
      end

      def inner_xml
        return unless @current

        if @current[:type] == ELEMENT
          frame = @current[:frame]
          expand_frame(frame)
          return enc("") if frame[:empty]

          return enc(slice_bytes(frame[:start_tag_end], frame[:end_offset]))
        end

        enc("")
      end

      private

      def field(key)
        @current && @current[key]
      end

      def element_frame
        return unless @current
        return unless @current[:type] == ELEMENT || @current[:type] == END_ELEMENT

        @current[:frame]
      end

      def encoding_label
        if @started
          @declared_encoding || @constructor_encoding || "UTF-8"
        else
          @constructor_encoding
        end
      end

      def enc(string)
        return if string.nil?

        text = string.dup
        text = text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::ASCII_8BIT
        text = text.scrub unless text.valid_encoding?
        label = encoding_label
        return text if label.nil? || label.casecmp("utf-8").zero?

        text.encode(label)
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError, ArgumentError
        text.dup.force_encoding(label)
      end

      def explode(message)
        error = XML::SyntaxError.new(message)
        error.instance_variable_set(:@level, 3)
        error.instance_variable_set(:@line, @line)
        error.instance_variable_set(:@column, @column)
        # Call the public method. An override that does not return an Array raises TypeError.
        (@error_owner ? @error_owner.errors : @errors) << error
        @failed = error
        @state = 2
        raise XML::SyntaxError, error.to_s
      end

      def pull_event
        prepare_prologue
        skip_space if @stack.empty?
        return if peek_byte.nil? && @stack.empty?
        explode("Extra content at the end of the document") if peek_byte.nil?

        if peek_byte == 60
          pull_markup
        elsif @stack.empty?
          explode("Start tag expected, '<' not found")
        else
          pull_text_or_entity
        end
      end

      def prepare_prologue
        return if @prologue_done

        consume_bom
        read_declaration if declaration_here?
        @prologue_done = true
      end

      def consume_bom
        return unless @pos.zero? && starts_with?("\xEF\xBB\xBF")

        advance(3)
      end

      def declaration_here?
        return false unless starts_with?("<?xml")

        fill_until(@pos + 6)
        byte = @buffer.getbyte(@pos + 5)
        [9, 10, 13, 32].include?(byte)
      end

      def read_declaration
        advance(5)
        pairs = read_declaration_pairs
        skip_space
        explode("xmlParsePI : no target name") unless starts_with?("?>")
        advance(2)
        @version = pair_value(pairs, "version")
        @declared_encoding = pair_value(pairs, "encoding")
      end

      def read_declaration_pairs
        pairs = []
        loop do
          skip_space
          break if starts_with?("?>") || peek_byte.nil?

          name = read_name
          explode("xmlParsePI : no target name") if name.nil?
          skip_space
          explode("Specification mandates value for attribute #{name}") unless peek_byte == 61
          advance
          skip_space
          pairs << [name, read_quoted]
        end
        pairs
      end

      def pair_value(pairs, key)
        pairs.assoc(key)&.last
      end

      def pull_markup
        if starts_with?("<!--")
          pull_comment
        elsif starts_with?("<![CDATA[")
          pull_cdata
        elsif starts_with?("<!DOCTYPE")
          pull_doctype
        elsif starts_with?("<?")
          pull_pi
        elsif starts_with?("</")
          pull_end_tag
        elsif starts_with?("<!")
          explode("Unsupported markup declaration")
        else
          pull_start_tag
        end
      end

      def pull_comment
        start = @pos
        advance(4)
        content_start = @pos
        consume_marker("-->")
        raw = slice_bytes(start, @pos)
        value = utf8(@buffer.byteslice(content_start, @pos - 3 - content_start))
        node(type: COMMENT, name: "#comment", local_name: "#comment", value: value, raw: raw, depth: @stack.length)
      end

      def pull_cdata
        explode("Start tag expected, '<' not found") if @stack.empty?

        start = @pos
        advance(9)
        content_start = @pos
        consume_marker("]]>")
        raw = slice_bytes(start, @pos)
        value = utf8(@buffer.byteslice(content_start, @pos - 3 - content_start))
        node(type: CDATA, name: "#cdata-section", local_name: "#cdata-section", value: value, raw: raw, depth: @stack.length)
      end

      def pull_pi
        start = @pos
        advance(2)
        target = read_name
        explode("xmlParsePI : no target name") if target.nil? || target.empty?
        skip_space
        body_start = @pos
        consume_marker("?>")
        raw = slice_bytes(start, @pos)
        value = utf8(@buffer.byteslice(body_start, @pos - 2 - body_start))
        node(type: PI, name: target, local_name: target, value: value, raw: raw, depth: @stack.length)
      end

      def pull_doctype
        explode("Extra content at the end of the document") if @seen_element || @seen_doctype

        @seen_doctype = true
        advance("<!DOCTYPE".bytesize)
        skip_space
        name = read_name
        explode("Start tag expected, '<' not found") if name.nil?
        skip_space
        system_id = nil
        if starts_with?("SYSTEM")
          advance(6)
          skip_space
          system_id = read_quoted
        elsif starts_with?("PUBLIC")
          advance(6)
          skip_space
          read_quoted
          skip_space
          system_id = read_quoted if quote_byte?(peek_byte)
        end
        skip_space
        parse_internal_subset if peek_byte == 91
        load_external_subset(system_id) if dtd_load? && system_id
        skip_space
        explode("Extra content at the end of the document") unless peek_byte == 62
        advance
        node(type: DOCUMENT_TYPE, name: name, local_name: name, value: "", raw: "", depth: 0)
      end

      def parse_internal_subset
        advance
        until peek_byte == 93 || peek_byte.nil?
          skip_space
          break if peek_byte == 93

          if starts_with?("<!--")
            advance(4)
            consume_marker("-->")
          elsif starts_with?("<?")
            advance(2)
            consume_marker("?>")
          elsif starts_with?("<!ENTITY")
            parse_entity_declaration
          elsif starts_with?("<!")
            skip_declaration
          else
            explode("Start tag expected, '<' not found")
          end
        end
        explode("Extra content at the end of the document") unless peek_byte == 93
        advance
      end

      def parse_entity_declaration
        advance("<!ENTITY".bytesize)
        skip_space
        if peek_byte == 37
          skip_declaration_rest
          return
        end

        name = read_name
        explode("xmlParseEntityDecl: no name") if name.nil?
        skip_space
        if starts_with?("SYSTEM") || starts_with?("PUBLIC")
          record_external_entity(name)
        else
          value = read_quoted
          @entities[name] ||= {external: false, value: value, base: @entity_base}
          skip_space
          explode("Extra content at the end of the document") unless peek_byte == 62
          advance
        end
      end

      def record_external_entity(name)
        if starts_with?("PUBLIC")
          advance(6)
          skip_space
          read_quoted
          skip_space
        else
          advance(6)
          skip_space
        end
        system_id = quote_byte?(peek_byte) ? read_quoted : nil
        skip_space
        unparsed = false
        if starts_with?("NDATA")
          advance(5)
          skip_space
          read_name
          unparsed = true
        end
        @entities[name] ||= {
          external: true,
          value: nil,
          system_id: system_id,
          unparsed: unparsed,
          base: @entity_base
        }
        skip_space
        explode("Extra content at the end of the document") unless peek_byte == 62
        advance
      end

      def load_external_subset(system_id)
        path = resolve_system_path(system_id, @url)
        return unless path

        saved = [@buffer, @pos, @line, @column, @eof, @io, @entity_base]
        @buffer = File.read(path).b
        @pos = 0
        @line = 1
        @column = 1
        @eof = true
        @io = nil
        @entity_base = path
        parse_external_declarations
      ensure
        @buffer, @pos, @line, @column, @eof, @io, @entity_base = saved if saved
      end

      def parse_external_declarations
        until peek_byte.nil?
          skip_space
          break if peek_byte.nil?

          if starts_with?("<!--")
            advance(4)
            consume_marker("-->")
          elsif starts_with?("<?")
            advance(2)
            consume_marker("?>")
          elsif starts_with?("<!ENTITY")
            parse_entity_declaration
          elsif starts_with?("<!")
            skip_declaration
          else
            break
          end
        end
      end

      def dtd_load?
        (@options & (XML::ParseOptions::DTDLOAD | XML::ParseOptions::DTDVALID)) != 0
      end

      def noent?
        (@options & XML::ParseOptions::NOENT) != 0
      end

      def resolve_system_path(system_id, base)
        return if system_id.nil? || system_id.empty?
        return if system_id.match?(/\A[a-z][a-z0-9+.-]*:/i)
        return system_id if system_id.start_with?("/") && File.file?(system_id)
        return if system_id.start_with?("/")
        return unless base

        directory = File.directory?(base) ? base : File.dirname(base)
        candidate = File.expand_path(system_id, directory)
        candidate if File.file?(candidate)
      end

      def skip_declaration
        advance(2)
        skip_declaration_rest
      end

      def skip_declaration_rest
        quote = nil
        loop do
          byte = peek_byte
          explode("Extra content at the end of the document") if byte.nil?
          advance
          if quote
            quote = nil if byte == quote
          elsif byte == 34 || byte == 39
            quote = byte
          elsif byte == 62
            break
          end
        end
      end

      def pull_start_tag
        explode("Extra content at the end of the document") if @stack.empty? && @seen_element

        start_offset = @pos
        open_line = @line
        advance
        qname = read_name
        explode("Start tag expected, '<' not found") if qname.nil? || qname.empty?
        items = []
        empty = false
        loop do
          skip_space
          if starts_with?("/>")
            advance(2)
            empty = true
            break
          elsif peek_byte == 62
            advance
            empty = false
            break
          else
            items << read_attribute_item
          end
        end

        frame = build_frame(qname, items, empty, start_offset, open_line)
        prefix, local = split_name(qname)
        event = node(
          type: ELEMENT,
          name: qname,
          local_name: local,
          prefix: prefix,
          namespace_uri: frame[:uri],
          value: nil,
          raw: nil,
          depth: @stack.length,
          lang: frame[:lang],
          base: frame[:base],
          empty: empty,
          frame: frame
        )
        unless empty
          push_context(frame)
          @stack << frame
        end
        @seen_element = true
        event
      end

      def pull_end_tag
        end_offset = @pos
        advance(2)
        qname = read_name
        explode("EndTag: '<' not found") if qname.nil?
        skip_space
        explode("Extra content at the end of the document") unless peek_byte == 62
        advance
        frame = @stack.last
        explode("Extra content at the end of the document") unless frame
        unless frame[:qname] == qname
          explode("Opening and ending tag mismatch: #{frame[:qname]} line #{frame[:open_line]} and #{qname}")
        end

        frame[:end_offset] = end_offset
        frame[:close_offset] = @pos
        frame[:closed] = true
        depth = @stack.length - 1
        @stack.pop
        pop_context
        node(
          type: END_ELEMENT,
          name: frame[:qname],
          local_name: frame[:local],
          prefix: frame[:prefix],
          namespace_uri: frame[:uri],
          value: nil,
          raw: nil,
          depth: depth,
          lang: frame[:lang],
          base: frame[:base],
          empty: false,
          frame: frame
        )
      end

      def build_frame(qname, items, empty, start_offset, open_line)
        prefix, local = split_name(qname)
        local_map = {}
        default_here = false
        default_value = nil
        items.each do |item|
          next unless item[:ns]

          if item[:prefix].nil?
            default_here = true
            default_value = item[:href]
          else
            local_map[item[:prefix]] = item[:href]
          end
        end
        uri = if prefix
          found = lookup_prefix(prefix, local_map)
          explode("Namespace prefix #{prefix} on #{qname} is not defined") if found.nil?
          found
        elsif default_here
          default_value
        else
          @default_ns.last
        end
        lang = items.find { |item| !item[:ns] && item[:prefix] == "xml" && item[:local] == "lang" }
        base_attr = items.find { |item| !item[:ns] && item[:prefix] == "xml" && item[:local] == "base" }
        lang_value = lang ? lang[:value] : @lang_stack.last
        base_value = if base_attr
          join_base(@base_stack.last, base_attr[:value])
        else
          @base_stack.last
        end
        {
          qname: qname,
          local: local,
          prefix: prefix,
          uri: uri,
          items: items,
          local_map: local_map,
          default_here: default_here,
          default_value: default_value,
          empty: empty,
          closed: empty,
          start_offset: start_offset,
          start_tag_end: @pos,
          end_offset: empty ? @pos : nil,
          close_offset: empty ? @pos : nil,
          open_line: open_line,
          lang: lang_value,
          base: base_value
        }
      end

      def push_context(frame)
        scope = @scopes.last.dup
        frame[:local_map].each { |prefix, href| scope[prefix] = href }
        @scopes << scope
        @default_ns << (frame[:default_here] ? frame[:default_value] : @default_ns.last)
        @lang_stack << frame[:lang]
        @base_stack << frame[:base]
      end

      def pop_context
        @scopes.pop
        @default_ns.pop
        @lang_stack.pop
        @base_stack.pop
      end

      def lookup_prefix(prefix, local_map)
        return XML_NS if prefix == "xml"
        return local_map[prefix] if local_map.key?(prefix)

        @scopes.reverse_each do |scope|
          return scope[prefix] if scope.key?(prefix)
        end
        nil
      end

      def read_attribute_item
        qname = read_name
        explode("Specification mandates value for attribute") if qname.nil?
        skip_space
        explode("Specification mandates value for attribute #{qname}") unless peek_byte == 61
        advance
        skip_space
        raw = read_quoted
        prefix, local = split_name(qname)
        if qname == "xmlns" || prefix == "xmlns"
          ns_prefix = (qname == "xmlns") ? nil : local
          href = expand_value(raw)
          {
            ns: true,
            qname: qname,
            prefix: ns_prefix,
            local: local,
            raw: raw,
            href: href,
            key: ns_prefix ? "xmlns:#{ns_prefix}" : "xmlns"
          }
        else
          {
            ns: false,
            qname: qname,
            prefix: prefix,
            local: local,
            raw: raw,
            value: expand_value(raw)
          }
        end
      end

      def pull_text_or_entity
        reference = reference_at_cursor
        if reference && reference[:kind] == :general
          return pull_general_entity(reference)
        end

        start = @pos
        loop do
          byte = peek_byte
          break if byte.nil? || byte == 60

          reference = reference_at_cursor if byte == 38
          if reference && reference[:kind] == :general
            break
          elsif reference && reference[:kind] == :undefined
            advance(reference[:length])
            explode("Entity '#{reference[:name]}' not defined")
          elsif reference && reference[:kind] == :broken
            explode("xmlParseEntityRef: no name")
          else
            advance
          end
          reference = nil
        end
        explode("Extra content at the end of the document") if @pos == start && peek_byte.nil?

        raw_bytes = @buffer.byteslice(start, @pos - start)
        decoded = Entities.decode_predefined(utf8(raw_bytes))
        type = decoded.match?(/\A[ \t\r\n]*\z/) ? SIGNIFICANT_WHITESPACE : TEXT
        node(
          type: type,
          name: "#text",
          local_name: "#text",
          value: decoded,
          raw: utf8(raw_bytes),
          depth: @stack.length
        )
      end

      def pull_general_entity(reference)
        advance(reference[:length])
        name = reference[:name]
        replacement = noent? ? entity_replacement(@entities[name]) : nil
        if !replacement.nil?
          explode("Detected a cycle in entity '#{name}'") if @expansion_depth >= 40

          bytes = replacement.b
          splice_bytes(bytes)
          @expansion_depth += 1
          @expansion_limits << (@pos + bytes.bytesize)
          @expansion_limits.sort!
          return pull_event
        end

        node(
          type: ENTITY_REFERENCE,
          name: name,
          local_name: name,
          value: "",
          raw: "&#{name};",
          depth: @stack.length
        )
      end

      def entity_replacement(record)
        return if record.nil? || record[:unparsed]
        return record[:value].to_s unless record[:external]

        path = resolve_system_path(record[:system_id], record[:base])
        return unless path

        File.read(path).sub(/\A\s*<\?xml\b.*?\?>/m, "")
      end

      def splice_bytes(bytes)
        text = bytes.to_s.b
        @expansion_limits.map! { |limit| (limit >= @pos) ? limit + text.bytesize : limit }
        head = @buffer.byteslice(0, @pos) || "".b
        tail = @buffer.byteslice(@pos..) || "".b
        @buffer = head + text + tail
      end

      def reference_at_cursor
        return unless peek_byte == 38

        fill_until(@pos + 2)
        return {kind: :broken} if @pos + 1 >= @buffer.bytesize

        if @buffer.getbyte(@pos + 1) == 35
          return character_reference
        end

        index = @pos + 1
        return {kind: :broken} unless name_start?(@buffer.getbyte(index))

        index += 1
        index += 1 while name_char?(@buffer.getbyte(index))
        fill_until(index + 1)
        return {kind: :broken} if index >= @buffer.bytesize || @buffer.getbyte(index) != 59

        name = utf8(@buffer.byteslice(@pos + 1, index - @pos - 1))
        length = index + 1 - @pos
        if Entities::PREDEFINED.key?(name)
          {kind: :predefined, name: name, length: length}
        elsif @entities.key?(name)
          {kind: :general, name: name, length: length}
        else
          {kind: :undefined, name: name, length: length}
        end
      end

      def character_reference
        hex = @buffer.getbyte(@pos + 2) == 120 || @buffer.getbyte(@pos + 2) == 88
        index = @pos + (hex ? 3 : 2)
        fill_until(index + 1)
        start = index
        while index < @buffer.bytesize && hex_or_digit?(@buffer.getbyte(index), hex)
          index += 1
          fill_until(index + 1)
        end
        return {kind: :broken} if index >= @buffer.bytesize || @buffer.getbyte(index) != 59 || index == start

        {kind: :char, length: index + 1 - @pos}
      end

      def hex_or_digit?(byte, hex)
        return false if byte.nil?
        return true if byte.between?(48, 57)
        return false unless hex

        byte.between?(65, 70) || byte.between?(97, 102)
      end

      def expand_value(raw, stack = [])
        text = raw.to_s
        result = +""
        index = 0
        while index < text.length
          if text[index] == "&"
            expanded, index = expand_reference(text, index, stack)
            result << expanded
          else
            result << text[index]
            index += 1
          end
        end
        result
      end

      def expand_reference(text, index, stack)
        match = text.match(/\G&(#x[0-9A-Fa-f]+|#\d+|[A-Za-z_:][\w.:-]*);/, index)
        explode("xmlParseEntityRef: no name") unless match

        body = match[1]
        if body.start_with?("#x", "#X")
          [body[2..].to_i(16).chr(Encoding::UTF_8), match.end(0)]
        elsif body.start_with?("#")
          [body[1..].to_i.chr(Encoding::UTF_8), match.end(0)]
        elsif Entities::PREDEFINED.key?(body)
          [Entities::PREDEFINED[body], match.end(0)]
        else
          record = @entities[body]
          explode("Entity '#{body}' not defined") if record.nil? || record[:external]
          explode("Detected a cycle in entity '#{body}'") if stack.include?(body)
          [expand_value(record[:value].to_s, stack + [body]), match.end(0)]
        end
      end

      def expand_frame(frame)
        return if frame[:empty] || frame[:closed]

        loop do
          event = pull_event
          explode("Extra content at the end of the document") if event.nil?
          @pending << event
          break if event[:type] == END_ELEMENT && event[:frame].equal?(frame)
        end
      end

      def serialize_empty(frame)
        body = "<#{frame[:qname]}"
        frame[:items].each do |item|
          raw = item[:raw].to_s.gsub('"', "&quot;")
          body << " #{item[:qname]}=\"#{raw}\""
        end
        body << "/>"
        body
      end

      def node(type:, name:, local_name:, value:, raw:, depth:, prefix: nil, namespace_uri: nil, lang: nil, base: nil, empty: false, frame: nil)
        {
          type: type,
          name: name,
          local_name: local_name,
          prefix: prefix,
          namespace_uri: namespace_uri,
          value: value,
          raw: raw,
          depth: depth,
          lang: lang || @lang_stack.last,
          base: base || @base_stack.last,
          empty: empty,
          frame: frame
        }
      end

      def join_base(parent, child)
        return child if child.nil? || child.empty?
        return child if child.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
        return child if parent.nil? || parent.empty?

        URI.join(parent, child).to_s
      rescue URI::InvalidURIError
        child
      end

      def split_name(qname)
        if qname.include?(":")
          prefix, local = qname.split(":", 2)
          [prefix, local]
        else
          [nil, qname]
        end
      end

      def read_name
        return unless name_start?(peek_byte)

        start = @pos
        advance
        advance while name_char?(peek_byte)
        utf8(@buffer.byteslice(start, @pos - start))
      end

      def read_quoted
        quote = peek_byte
        explode("AttValue: \" or ' expected") unless quote == 34 || quote == 39
        advance
        start = @pos
        loop do
          byte = peek_byte
          explode("Extra content at the end of the document") if byte.nil?
          break if byte == quote

          advance
        end
        value = utf8(@buffer.byteslice(start, @pos - start))
        advance
        value
      end

      def consume_marker(marker)
        loop do
          if starts_with?(marker)
            advance(marker.bytesize)
            return
          end
          explode("Extra content at the end of the document") if peek_byte.nil?
          advance
        end
      end

      def skip_space
        advance while space_byte?(peek_byte)
      end

      def name_start?(byte)
        return false if byte.nil?
        return true if byte >= 128

        byte.between?(65, 90) || byte.between?(97, 122) || byte == 95 || byte == 58
      end

      def name_char?(byte)
        return false if byte.nil?
        return true if byte >= 128

        name_start?(byte) || byte.between?(48, 57) || byte == 45 || byte == 46
      end

      def space_byte?(byte)
        byte == 32 || byte == 9 || byte == 10 || byte == 13
      end

      def quote_byte?(byte)
        byte == 34 || byte == 39
      end

      def starts_with?(text)
        bytes = text.b
        fill_until(@pos + bytes.bytesize)
        @buffer.byteslice(@pos, bytes.bytesize) == bytes
      end

      def slice_bytes(from, to)
        utf8(@buffer.byteslice(from, to - from))
      end

      def utf8(bytes)
        return "" if bytes.nil?

        text = bytes.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub
      end

      def peek_byte
        fill_until(@pos + 1)
        return if @pos >= @buffer.bytesize

        @buffer.getbyte(@pos)
      end

      def advance(count = 1)
        count.times do
          byte = peek_byte
          break if byte.nil?

          @pos += 1
          if byte == 10
            @line += 1
            @column = 1
          else
            @column += 1
          end
          release_expansions
        end
      end

      def release_expansions
        while @expansion_limits.any? && @pos >= @expansion_limits.first
          @expansion_limits.shift
          @expansion_depth -= 1
        end
      end

      def fill_until(size)
        while @buffer.bytesize < size && !@eof
          fill_chunk
        end
      end

      def fill_chunk
        return if @io.nil? || @eof

        # As in libxml2, a StandardError from the IO is a failed read. Any
        # other exception, such as Interrupt, goes to the caller.
        chunk = begin
          @io.read(CHUNK)
        rescue
          nil
        end
        unless chunk.is_a?(String)
          @eof = true
          return
        end

        @buffer << chunk.b
      end
    end
  end

  module XML
    class Reader
      def self.from_memory(buffer, url = nil, encoding = nil, options = 0)
        raise ArgumentError, "string cannot be nil" if buffer.nil?

        reader = allocate
        reader.send(:initialize, buffer, url, encoding)
        reader.send(:install_cursor, buffer, url, encoding, io: false, options: options)
        reader
      end

      def self.from_io(io, url = nil, encoding = nil, options = 0)
        raise ArgumentError, "io cannot be nil" if io.nil?

        reader = allocate
        reader.send(:initialize, io, url, encoding)
        reader.send(:install_cursor, io, url, encoding, io: true, options: options)
        reader
      end

      def empty_element?
        cursor.empty_element?
      end

      def attribute(name)
        cursor.attribute(name)
      end

      def attribute_at(index)
        cursor.attribute_at(index)
      end

      def attribute_count
        cursor.attribute_count
      end

      def attribute_hash
        cursor.attribute_hash
      end

      def attributes?
        cursor.attributes?
      end

      def base_uri
        cursor.base_uri
      end

      def default?
        cursor.default?
      end

      def depth
        cursor.depth
      end

      def encoding
        cursor.encoding
      end

      def inner_xml
        cursor.inner_xml
      end

      def lang
        cursor.lang
      end

      def local_name
        cursor.local_name
      end

      def name
        cursor.name
      end

      def namespace_uri
        cursor.namespace_uri
      end

      def namespaces
        cursor.namespaces
      end

      def node_type
        cursor.node_type
      end

      def outer_xml
        cursor.outer_xml
      end

      def prefix
        cursor.prefix
      end

      def read
        cursor.read ? self : nil
      end

      def state
        cursor.state
      end

      def value
        cursor.value
      end

      def value?
        cursor.value?
      end

      def xml_version
        cursor.xml_version
      end

      private

      def install_cursor(source, url, encoding, io:, options: 0)
        @cursor = Pure::ReaderCursor.new(
          source: source,
          url: url,
          encoding: encoding,
          errors: @errors,
          error_owner: self,
          io: io,
          options: options
        )
      end

      attr_reader :cursor
    end
  end
end
