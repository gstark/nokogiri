# frozen_string_literal: true

require "strscan"

module Nokogiri
  module Pure
    # SAX driver. It walks the same XML the DOM parser accepts and sends
    # events to a SAX::Document. XML recovery is off unless the context asks.
    class SaxParser
      NAME = /[\p{L}_:][\p{L}\p{N}_:.-]*/
      XML_NS = "http://www.w3.org/XML/1998/namespace"

      def initialize(context, handler)
        @context = context
        @handler = handler
        @html = context.is_a?(Nokogiri::HTML4::SAX::ParserContext)
        @replace_entities = context.replace_entities
        @recovery = context.recovery
        @scaffolded = false
        @scanner = StringScanner.new(decode(context.raw_input, context.forced_encoding))
        @line = 1
        @column = 0
        @stack = []
        @scopes = []
        @entities = {}
        @open_entities = []
        @stopped = false
        @seen_element = false
        @push = false
        @started = false
      end

      def self.for_push(handler, html: false)
        parser = allocate
        parser.send(:setup_push, handler, html)
        parser
      end

      def feed(string, finishing:, recovery:, replace_entities:)
        @recovery = recovery
        @replace_entities = replace_entities
        @finishing = finishing
        append_source(string.to_s)
        emit_prologue
        parse_loop
        if finishing && !@stopped
          finish_document
        end
        if finishing && (!@stopped || @recovery) && @started
          callback(:end_document)
        end
        raise XML::SyntaxError, @last_error if @stopped && !@recovery && @last_error

        nil
      end

      def parse
        if declaration?
          version, encoding, standalone = read_declaration
          callback(:xmldecl, version, encoding, standalone)
        end
        callback(:start_document)
        parse_loop
        finish_document
        callback(:end_document)
        nil
      end

      private

      def decode(input, forced)
        bytes = input.to_s.b
        bom = "\xEF\xBB\xBF".b
        bytes = bytes.byteslice(bom.bytesize..) if bytes.start_with?(bom)
        bytes = bytes.gsub("\r\n".b, "\n".b).gsub("\r".b, "\n".b)
        encoding = forced || html_meta_encoding(bytes) || declared_encoding(bytes) || Encoding::UTF_8
        text = bytes.force_encoding(encoding)
        if text.valid_encoding?
          text.encode(Encoding::UTF_8)
        else
          error("Input is not proper UTF-8, indicate encoding !") if @push
          text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end
      end

      def html_meta_encoding(bytes)
        return unless @html && !@push

        head = bytes.byteslice(0, 2048).dup.force_encoding(Encoding::ASCII_8BIT)
        match = head.match(/charset\s*=\s*["']?([A-Za-z0-9_.:-]+)/i)
        return unless match

        Encoding.find(match[1])
      rescue ArgumentError
        nil
      end

      def declared_encoding(bytes)
        return unless bytes.start_with?("<?xml".b)
        return unless bytes.bytesize > 5 && [9, 10, 13, 32].include?(bytes.getbyte(5))

        # The declaration is ASCII. The body may not be valid in UTF-8.
        decl_end = bytes.index("?>".b)
        head_bytes = decl_end ? bytes.byteslice(0, decl_end + 2) : bytes.byteslice(0, 400)
        head = head_bytes.dup.force_encoding(Encoding::UTF_8)
        return unless head.valid_encoding?

        match = head.match(/encoding\s*=\s*["']([^"']+)["']/)
        return unless match

        Encoding.find(match[1])
      rescue ArgumentError
        nil
      end

      def declaration?
        rest = @scanner.rest
        rest.start_with?("<?xml") && rest[5]&.match?(/\s/)
      end

      def setup_push(handler, html)
        @context = nil
        @handler = handler
        @html = html
        @scaffolded = false
        @replace_entities = true
        @recovery = false
        @source_buffer = +""
        @scanner = StringScanner.new(@source_buffer)
        @line = 1
        @column = 0
        @stack = []
        @scopes = []
        @entities = {}
        @open_entities = []
        @stopped = false
        @seen_element = false
        @push = true
        @finishing = false
        @started = false
        @last_error = nil
      end

      def append_source(string)
        decoded = decode(string, nil)
        return if decoded.empty?

        position = @scanner.pos
        @source_buffer << decoded
        @scanner.string = @source_buffer
        @scanner.pos = position
      end

      def emit_prologue
        return if @started
        return if @push && !@finishing && prologue_incomplete?

        if declaration?
          version, encoding, standalone = read_declaration
          callback(:xmldecl, version, encoding, standalone)
        end
        callback(:start_document)
        @started = true
      end

      def prologue_incomplete?
        rest = @scanner.rest
        rest.start_with?("<?xml") && rest[5]&.match?(/\s/) && !rest.include?("?>")
      end

      def parse_loop
        scanner = @scanner
        until scanner.eos? || @stopped
          if scanner.string.getbyte(scanner.pos) == 60
            break if @push && !@finishing && !markup_complete?

            parse_markup
          else
            handle_text(read_before("<"))
          end
        end
      end

      def markup_complete?
        source = @scanner.string
        pos = @scanner.charpos
        head = source[pos, 9].to_s
        if head.start_with?("<!--")
          !source.index("-->", pos).nil?
        elsif head.start_with?("<![CDATA[")
          !source.index("]]>", pos).nil?
        elsif head.start_with?("<?")
          !source.index("?>", pos).nil?
        elsif head.start_with?("<!")
          !source.index(">", pos).nil?
        else
          quote = nil
          while pos < source.length
            found = source.index(/["'>]/, pos)
            return false unless found

            char = source[found]
            if quote
              quote = nil if char == quote
            elsif char == "'" || char == '"'
              quote = char
            else
              return true
            end
            pos = found + 1
          end
          false
        end
      end

      def html?
        @html
      end

      def void_html?(name)
        Parser.void_html_names[name]
      end

      def open_html_scaffold(local)
        return unless html?
        return if @scaffolded || @stack.any?
        return if local == "html"

        @scaffolded = true
        callback(:start_element_namespace, "html", [], nil, nil, [])
        callback(:start_element_namespace, "head", [], nil, nil, [])
        callback(:end_element_namespace, "head", nil, nil)
        callback(:start_element_namespace, "body", [], nil, nil, [])
      end

      def finish_document
        if html?
          while (frame = @stack.pop)
            callback(:end_element_namespace, frame[:local], frame[:prefix], frame[:uri])
          end
          if @scaffolded
            callback(:end_element_namespace, "body", nil, nil)
            callback(:end_element_namespace, "html", nil, nil)
          end
          return
        end

        return if @stopped

        if @stack.any?
          element = @stack.last
          error("Premature end of data in tag #{element[:qname]} line #{element[:line]}")
        elsif !@seen_element
          error("Start tag expected, '<' not found")
        end
      end

      def parse_markup
        string = @scanner.string
        pos = @scanner.pos
        byte = string.getbyte(pos + 1)
        if byte == 33
          second = string.getbyte(pos + 2)
          if second == 45 && string.getbyte(pos + 3) == 45
            callback(:comment, read_marked("<!--", "-->"))
          elsif second == 91 && string.byteslice(pos, 9) == "<![CDATA["
            callback(:cdata_block, read_marked("<![CDATA[", "]]>"))
          elsif second == 68 && string.byteslice(pos, 9) == "<!DOCTYPE"
            read_doctype
          else
            error("Unsupported markup declaration")
            read_before(">")
            consume(">")
          end
        elsif byte == 63
          read_pi
        elsif byte == 47
          read_end_tag
        else
          read_start_tag
        end
      end

      def read_declaration
        consume("<?xml")
        attributes = read_attribute_pairs
        skip_space
        consume("?>")
        [
          attributes.assoc("version")&.last,
          attributes.assoc("encoding")&.last,
          attributes.assoc("standalone")&.last
        ]
      end

      def read_start_tag
        if @stack.empty? && @seen_element && !html? && !@recovery
          error("Extra content at the end of the document")
          @stopped = true
          return
        end

        consume("<")
        tag_line = @line
        qname = read_name
        qname = qname.downcase if html?
        if qname.empty?
          error("StartTag: invalid element name")
          return
        end

        pairs = read_attribute_pairs
        return if @stopped

        skip_space
        self_closing = false
        if @scanner.check(/\/>/)
          consume("/>")
          self_closing = true
        else
          consume(">")
        end
        return if @stopped

        prefix, local = split_name(qname)
        local = local.downcase if html?
        namespaces, attributes = partition_attributes(pairs)
        return if @stopped

        uri = prefix ? lookup_prefix(prefix, namespaces) : lookup_default(namespaces)
        open_html_scaffold(local)
        @seen_element = true
        callback(
          :start_element_namespace,
          local,
          attributes,
          prefix,
          uri,
          namespaces
        )
        return if @stopped

        if self_closing || (html? && void_html?(local))
          callback(:end_element_namespace, local, prefix, uri)
          return
        end

        @stack << {qname: qname, local: local, prefix: prefix, uri: uri, line: tag_line}
        @scopes << namespaces
      end

      def read_end_tag
        consume("</")
        qname = read_name
        qname = qname.downcase if html?
        skip_space
        consume(">")
        if html? && @stack.none? { |frame| frame[:qname] == qname }
          if qname == "p" || qname == "br"
            callback(:start_element_namespace, qname, [], nil, nil, [])
            callback(:end_element_namespace, qname, nil, nil)
          end
          return
        end

        frame = @stack.last
        if frame && frame[:qname] == qname
          @stack.pop
          @scopes.pop
          callback(:end_element_namespace, frame[:local], frame[:prefix], frame[:uri])
          return
        end

        error("Opening and ending tag mismatch: #{frame ? frame[:qname] : qname} line #{frame ? frame[:line] : @line} and #{qname}")
        return if @stopped

        until @stack.empty?
          closed = @stack.pop
          @scopes.pop
          callback(:end_element_namespace, closed[:local], closed[:prefix], closed[:uri])
          break if closed[:qname] == qname
        end
      end

      def read_pi
        consume("<?")
        target = read_name
        if target == "xml"
          error("XML declaration allowed only at the start of the document")
          return if @stopped
        end
        if target.empty?
          error("xmlParsePI : no target name")
          return
        end

        skip_space
        body = read_before("?>")
        consume("?>")
        return if @stopped

        callback(:processing_instruction, target, body)
      end

      def read_doctype
        consume("<!DOCTYPE")
        skip_space
        read_name
        skip_space
        if @scanner.check(/PUBLIC/)
          consume("PUBLIC")
          skip_space
          read_quoted
          skip_space
          read_quoted if @scanner.check(/['"]/)
        elsif @scanner.check(/SYSTEM/)
          consume("SYSTEM")
          skip_space
          read_quoted
        end
        skip_space
        read_internal_subset if @scanner.check(/\[/)
        skip_space
        consume(">")
      end

      def read_internal_subset
        consume("[")
        until @scanner.eos? || @stopped || @scanner.check(/\]/)
          skip_space
          break if @scanner.check(/\]/)

          if @scanner.check(/<!--/)
            callback(:comment, read_marked("<!--", "-->"))
          elsif @scanner.check(/<\?/)
            read_pi
          elsif @scanner.check(/<!ENTITY/)
            read_entity_declaration
          elsif @scanner.check(/<!/)
            skip_declaration
          else
            take_char
          end
        end
        consume("]")
      end

      def read_entity_declaration
        consume("<!ENTITY")
        skip_space
        parameter = false
        if @scanner.check(/%/)
          consume("%")
          parameter = true
          skip_space
        end
        name = read_name
        skip_space
        if @scanner.check(/PUBLIC/)
          consume("PUBLIC")
          skip_space
          read_quoted
          skip_space
          system_id = read_quoted
          ndata = read_ndata
          store_entity(name, {kind: :external, system_id: system_id, ndata: ndata}) unless parameter
        elsif @scanner.check(/SYSTEM/)
          consume("SYSTEM")
          skip_space
          system_id = read_quoted
          ndata = read_ndata
          store_entity(name, {kind: :external, system_id: system_id, ndata: ndata}) unless parameter
        else
          value = read_quoted
          store_entity(name, {kind: :internal, value: value}) unless parameter
        end
        skip_space
        consume(">")
      end

      def read_ndata
        skip_space
        return unless @scanner.check(/NDATA/)

        consume("NDATA")
        skip_space
        read_name
      end

      def store_entity(name, record)
        return if name.empty?

        @entities[name] ||= record
      end

      def skip_declaration
        consume("<!")
        quote = nil
        until @scanner.eos?
          char = take_char
          break if char.nil?
          if quote
            quote = nil if char == quote
            next
          end
          case char
          when "'", '"'
            quote = char
          when ">"
            break
          end
        end
      end

      def partition_attributes(pairs)
        namespaces = []
        attributes = []
        pairs.each do |name, raw|
          value = raw.nil? ? nil : expand_attribute(raw)
          return [[], []] if @stopped && !@recovery

          if name == "xmlns"
            warn_namespace(value)
            namespaces << [nil, value]
          elsif name.start_with?("xmlns:")
            warn_namespace(value)
            namespaces << [name.split(":", 2).last, value]
          else
            prefix, local = split_name(name)
            uri = prefix ? lookup_prefix(prefix, namespaces) : nil
            attributes << XML::SAX::Parser::Attribute.new(local, prefix, uri, value)
          end
        end
        [namespaces, attributes]
      end

      def expand_attribute(raw)
        output = +""
        scanner = StringScanner.new(raw)
        until scanner.eos?
          if (literal = scanner.scan(/[^&]+/))
            output << literal
          elsif scanner.scan(/&#(\d+);/)
            output << attribute_codepoint(scanner[1].to_i)
          elsif scanner.scan(/&#[xX]([0-9A-Fa-f]+);/)
            output << attribute_codepoint(scanner[1].to_i(16))
          elsif (raw = scanner.scan(/&([A-Za-z_:][\w.:-]*);/))
            output << attribute_entity(scanner[1], raw)
            return output if @stopped && !@recovery
          else
            output << scanner.getch
          end
        end
        output
      end

      def attribute_codepoint(code)
        return @replace_entities ? "&" : "&#38;" if code == 38

        Entities.codepoint_char(code)
      end

      def attribute_entity(name, raw)
        if name == "amp"
          @replace_entities ? "&" : "&#38;"
        elsif Entities::PREDEFINED.key?(name)
          Entities::PREDEFINED[name]
        elsif (entity = @entities[name])
          if @replace_entities && entity[:kind] == :internal && entity[:ndata].nil?
            entity[:value].to_s
          elsif @replace_entities && entity[:kind] == :external && entity[:ndata].nil?
            load_system(entity[:system_id]).to_s
          else
            raw
          end
        else
          error("Entity '#{name}' not defined")
          ""
        end
      end

      def handle_text(text)
        return if text.empty?
        if @stack.empty?
          return if text.match?(/\A\s*\z/)

          error(@seen_element ? "Extra content at the end of the document" : "Start tag expected, '<' not found")
          @stopped = true unless @recovery
          return
        end

        emit_text(text)
      end

      def emit_text(text)
        buffer = +""
        scanner = StringScanner.new(text)
        until scanner.eos? || @stopped
          if (literal = scanner.scan(/[^&]+/))
            buffer << literal
          elsif scanner.scan(/&#(\d+);/)
            buffer << Entities.codepoint_char(scanner[1].to_i)
          elsif scanner.scan(/&#[xX]([0-9A-Fa-f]+);/)
            buffer << Entities.codepoint_char(scanner[1].to_i(16))
          elsif (raw = scanner.scan(/&([A-Za-z_:][\w.:-]*);/))
            name = scanner[1]
            if Entities::PREDEFINED.key?(name)
              buffer << Entities::PREDEFINED[name]
            else
              emit_characters(buffer)
              buffer = +""
              expand_content_entity(name, raw)
            end
          else
            buffer << scanner.getch
          end
        end
        emit_characters(buffer)
      end

      def expand_content_entity(name, raw)
        entity = @entities[name]
        if entity.nil?
          error("Entity '#{name}' not defined")
          callback(:reference, name, nil) unless @replace_entities
          return
        end

        if entity[:kind] == :external
          if @replace_entities && entity[:ndata].nil? && (text = load_system(entity[:system_id]))
            expand_replacement(text)
          elsif !@replace_entities
            callback(:reference, name, nil)
          end
          return
        end

        if @open_entities.include?(name)
          error("Detected an entity reference loop")
          return
        end

        @open_entities << name
        expand_replacement(entity[:value].to_s)
        @open_entities.pop
        callback(:reference, name, entity[:value]) unless @replace_entities
      end

      def expand_replacement(text)
        saved_scanner = @scanner
        saved_line = @line
        saved_column = @column
        @scanner = StringScanner.new(text)
        parse_loop
      ensure
        @scanner = saved_scanner
        @line = saved_line
        @column = saved_column
      end

      def load_system(system_id)
        return if system_id.nil? || system_id.empty?
        return if system_id.match?(/\A[a-z][a-z0-9+.-]*:/i) && !system_id.start_with?("file:")

        path = system_id.sub(/\Afile:\/\//, "")
        return unless File.file?(path)

        bytes = File.binread(path)
        text = bytes.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : bytes.b
      end

      def emit_characters(text)
        return if text.empty?

        callback(:characters, text.dup)
      end

      def warn_namespace(value)
        return if value.nil? || value.empty?
        return if value.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)

        callback(:warning, "URI #{value} is not absolute\n")
      end

      def lookup_prefix(prefix, local_namespaces)
        return XML_NS if prefix == "xml"
        return "http://www.w3.org/2000/xmlns/" if prefix == "xmlns"

        found = find_binding(prefix, local_namespaces)
        return found unless found.nil?

        @scopes.reverse_each do |frame|
          found = find_binding(prefix, frame)
          return found unless found.nil?
        end
        nil
      end

      def lookup_default(local_namespaces)
        [local_namespaces, *@scopes.reverse].each do |frame|
          frame.reverse_each do |prefix, uri|
            next unless prefix.nil?

            return nil if uri.nil? || uri.empty?

            return uri
          end
        end
        nil
      end

      def find_binding(prefix, frame)
        frame.reverse_each do |candidate, uri|
          return uri if candidate == prefix
        end
        nil
      end

      def read_attribute_pairs
        pairs = []
        loop do
          skip_space
          break if @scanner.eos? || @scanner.check(/[>\/?\]]/)

          name = read_name
          break if name.empty?

          name = name.downcase if html?
          skip_space
          if html? && !@scanner.check(/=/)
            pairs << [name, nil]
            next
          end
          consume("=")
          skip_space
          pairs << [name, read_quoted]
          return pairs if @stopped
        end
        pairs
      end

      def read_quoted
        quote = take_char
        unless quote == '"' || quote == "'"
          error('AttValue: " or \' expected')
          return ""
        end

        string = @scanner.string
        pos = @scanner.pos
        limit = string.bytesize
        qbyte = quote.getbyte(0)
        cursor = pos
        while cursor < limit && string.getbyte(cursor) != qbyte
          cursor += 1
        end
        value = string.byteslice(pos, cursor - pos) || +""
        @scanner.pos = cursor
        account(value) unless value.empty?
        take_char if cursor < limit
        value
      end

      def read_marked(open_marker, close_marker)
        consume(open_marker)
        body = read_before(close_marker)
        consume(close_marker)
        body
      end

      # Read up to +marker+ and leave the marker for the caller to consume.
      def read_before(marker)
        chunk = @scanner.scan_until(marker_pattern(marker))
        unless chunk
          rest = @scanner.rest
          @scanner.terminate
          account(rest)
          return rest
        end

        body = chunk[0...-marker.length]
        account(body)
        @scanner.pos -= marker.bytesize
        body
      end

      def read_name
        skip_space
        match = @scanner.check(NAME)
        return "" unless match

        consume(match)
        match
      end

      def split_name(qname)
        return [nil, qname] unless qname.include?(":")

        prefix, local = qname.split(":", 2)
        [prefix, local]
      end

      def skip_space
        string = @scanner.string
        pos = @scanner.pos
        limit = string.bytesize
        start = pos
        while pos < limit
          byte = string.getbyte(pos)
          break unless byte == 32 || byte == 9 || byte == 10 || byte == 13

          pos += 1
        end
        return if pos == start

        @scanner.pos = pos
        account(string.byteslice(start, pos - start))
      end

      def consume(token)
        remaining = @scanner.string.bytesize - @scanner.pos
        if token.bytesize > remaining
          rest = @scanner.rest
          @scanner.terminate
          account(rest) unless rest.empty?
          return true
        end

        @scanner.pos += token.bytesize
        account(token)
        true
      end

      def marker_pattern(marker)
        @marker_patterns ||= {}
        @marker_patterns[marker] ||= Regexp.new(Regexp.escape(marker))
      end

      def take_char
        char = @scanner.getch
        return unless char

        account(char)
        char
      end

      def account(string)
        if (index = string.rindex("\n"))
          @line += string.count("\n")
          @column = string.length - index - 1
        else
          @column += string.length
        end
      end

      def callback(method, *args)
        if @context
          @context.line = @line
          @context.column = @column
        end
        @handler.public_send(method, *args)
      end

      def error(message)
        @last_error = "#{message}\n"
        callback(:error, @last_error)
        @stopped = true unless @recovery
      end
    end
  end

  module XML
    module SAX
      class ParserContext
        attr_accessor :line, :column, :raw_input, :forced_encoding

        class << self
          def native_memory(input, encoding)
            unless input.is_a?(String)
              raise TypeError, "wrong argument type #{type_name(input)} (expected String)"
            end
            raise "input string cannot be empty" if input.empty?

            build_context(input, encoding)
          end

          def native_io(input, encoding)
            raise TypeError, "argument expected to respond to :read" unless input.respond_to?(:read)

            data = input.read
            data = "" if data.nil?
            build_context(data, encoding)
          end

          def native_file(path, encoding = nil)
            unless path.respond_to?(:to_str)
              raise TypeError, "no implicit conversion of #{type_name(path)} into String"
            end

            bytes = File.binread(path.to_str)
            bytes = gunzip(bytes) if gzip?(bytes)
            build_context(bytes, encoding)
          end

          def gzip?(bytes)
            bytes.bytesize >= 2 && bytes.getbyte(0) == 0x1F && bytes.getbyte(1) == 0x8B
          end

          def gunzip(bytes)
            require "zlib"
            require "stringio"
            Zlib::GzipReader.new(StringIO.new(bytes)).read
          end

          def build_context(input, encoding)
            if !encoding.nil? && !encoding.is_a?(Encoding)
              raise TypeError, "argument must be an Encoding object"
            end

            context = allocate
            context.send(:prepare_parse, input, encoding)
            context
          end

          def type_name(input)
            case input
            when nil then "nil"
            when true then "true"
            when false then "false"
            else input.class.name
            end
          end
        end

        def parse_with(parser)
          unless parser.is_a?(XML::SAX::Parser)
            raise ArgumentError, "argument must be a Nokogiri::XML::SAX::Parser"
          end

          Pure::SaxParser.new(self, parser.document).parse
          nil
        end

        attr_reader :replace_entities

        def replace_entities=(value)
          @replace_entities = !value.nil? && value != false
          value
        end

        attr_reader :recovery

        def recovery=(value)
          @recovery = !value.nil? && value != false
          value
        end

        private

        def prepare_parse(input, encoding)
          @raw_input = input
          @forced_encoding = encoding
          @replace_entities = false
          @recovery = is_a?(Nokogiri::HTML4::SAX::ParserContext)
          @line = 1
          @column = 0
        end
      end

      class PushParser
        def initialize_native(_sax_parser, _filename = nil, encoding = nil)
          @options = 0
          @replace_entities = false
          @syntax_error = nil
          @push_session = nil
          @forced_encoding = encoding
        end

        attr_reader :options

        def options=(value)
          @options = Integer(value)
          value
        end

        attr_reader :replace_entities

        def replace_entities=(value)
          @replace_entities = !value.nil? && value != false
          value
        end

        private

        def html_push?
          is_a?(Nokogiri::HTML4::SAX::PushParser)
        end

        def native_write(chunk, last_chunk)
          raise @syntax_error if @syntax_error

          @push_session ||= Pure::SaxParser.for_push(document, html: html_push?)
          text = chunk.nil? ? "" : chunk.to_s
          begin
            @push_session.feed(
              text,
              finishing: last_chunk == true,
              recovery: html_push? || (@options & XML::ParseOptions::RECOVER) != 0,
              replace_entities: @replace_entities
            )
          rescue XML::SyntaxError => error
            @syntax_error = error
            raise
          end
          self
        end
      end
    end
  end
end
