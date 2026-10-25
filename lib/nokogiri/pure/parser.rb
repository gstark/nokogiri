# frozen_string_literal: true

require "strscan"

module Nokogiri
  module Pure
    # XML parser for the pure Ruby backend.
    class Parser
      RECOVER = 1
      NAME = /[\p{L}_:][\p{L}\p{N}_:.\-]*/.freeze
      UNQUOTED = /[^\s>\/]*/
      QUOTED_DQ = /[^"&]+/
      QUOTED_SQ = /[^'&]+/
      AMP_START = /[#A-Za-z_:]/
      SPACE_RUN = /\s+/

      def self.parse(document, string, options)
        new(document, string, options).parse_document
        document
      end

      # Return unparented nodes parsed from a fragment string.
      def self.parse_fragment(document, string, context, options)
        holder = XML::DocumentFragment.allocate
        State.attach(
          holder,
          type: XML::Node::DOCUMENT_FRAG_NODE,
          name: "#document-fragment",
          document: document,
        )
        new(document, string, options, root: holder, context: context).parse_document
        holder.pure.children.dup.each(&:unlink)
      end

      def initialize(document, string, options, root: nil, context: nil)
        @document = document
        @root = root || document
        @context = context
        @options = options.to_i
        source = string.to_s.dup
        if source.encoding == Encoding::UTF_8 || source.encoding == Encoding::US_ASCII
          source.delete_prefix!("\uFEFF")
        elsif source.bytesize >= 3 && source.getbyte(0) == 0xEF && source.getbyte(1) == 0xBB && source.getbyte(2) == 0xBF
          source = source.byteslice(3..) || +""
          source.force_encoding(Encoding::UTF_8)
        end
        source = source.dup.force_encoding(Encoding::UTF_8).scrub unless source.valid_encoding?
        @scanner = StringScanner.new(source)
        @line = 1
        @column = 1
        @stack = []
        @scopes = [inherited_scopes(context)]
      end

      def parse_document
        # A declaration is recognized only at the first character.
        fatals_before = @document.errors.count(&:fatal?)
        if @scanner.string.start_with?("<?xml") && @scanner.charpos.zero?
          read_xml_declaration
        end
        parse_loop
        if @stack.any? && @document.errors.count(&:fatal?) == fatals_before
          element = @stack.last
          error("Premature end of data in tag #{element.name} line #{element.line}")
        end
        @stack.clear
        ensure_html_tree
        if strict? && @root.document? && @root.pure.children.none?(&:element?) && @scanner.string.strip.empty?
          error("Start tag expected, '<' not found")
        end
        ensure_html_dtd if @root.document?
        record_validity_errors if @root.document? && (@options & XML::ParseOptions::DTDVALID) != 0
      end

      def ensure_html_dtd
        return unless html_document?
        return if @document.internal_subset

        dtd = build_dtd(
          "html",
          "-//W3C//DTD HTML 4.0 Transitional//EN",
          "http://www.w3.org/TR/REC-html40/loose.dtd",
        )
        dtd.pure.parent = @document
        @document.pure.children.unshift(dtd)
      end

      private

      def parse_loop
        scanner = @scanner
        until scanner.eos?
          # "<" is one ASCII byte, including inside a UTF-8 document.
          if scanner.string.getbyte(scanner.pos) == 60
            if html_document? && !html_markup?
              append_text(take_char.to_s)
            else
              parse_markup
            end
          else
            append_text(read_until_markup)
          end
        end
      end

      def html_markup?
        string = @scanner.string
        pos = @scanner.pos
        byte = string.getbyte(pos + 1)
        return false unless byte
        return true if byte == 33 || byte == 63

        if byte == 47
          next_byte = string.getbyte(pos + 2)
          return false unless next_byte

          return (next_byte >= 65 && next_byte <= 90) || (next_byte >= 97 && next_byte <= 122)
        end

        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
      end

      def parse_markup
        string = @scanner.string
        pos = @scanner.pos
        byte = string.getbyte(pos + 1)
        if byte == 33
          second = string.getbyte(pos + 2)
          if second == 45 && string.getbyte(pos + 3) == 45
            append_node(read_comment)
          elsif second == 91 && string.byteslice(pos, 9) == "<![CDATA["
            append_node(read_cdata)
          elsif second == 68 && string.byteslice(pos, 9) == "<!DOCTYPE"
            append_node(read_doctype)
          else
            error("Unsupported markup declaration")
            skip_through(">")
          end
        elsif byte == 63
          append_node(read_pi)
        elsif byte == 47
          read_end_tag
        else
          read_start_tag
        end
      end

      def read_xml_declaration
        advance("<?xml")
        attributes = read_attributes
        skip_space
        advance("?>")
        @document.pure.version = attributes["version"] if attributes["version"]
        @document.encoding = attributes["encoding"] if attributes["encoding"]
      end

      def read_start_tag
        advance("<")
        line = @line
        qname = read_name
        qname.downcase! if html_document? && !qname.empty?
        if qname.empty?
          error("StartTag: invalid element name")
          return
        end
        attributes = read_attributes
        skip_space
        self_closing = false
        string = @scanner.string
        mark = @scanner.pos
        if string.getbyte(mark) == 47 && string.getbyte(mark + 1) == 62
          advance("/>")
          self_closing = true
        else
          expect(">")
        end

        element = make_node(XML::Element, XML::Node::ELEMENT_NODE, qname, nil, line)
        apply_namespaces(element, qname, attributes)
        append_node(element)
        unless self_closing || void_html?(element.name)
          @stack << element
          @scopes << element.namespace_definitions
        end
      end

      def read_end_tag
        advance("</")
        qname = read_name
        skip_space
        expect(">")
        name = local_name(qname)
        name.downcase! if html_document? && !name.empty?
        if html_document? && @stack.none? { |node| node.name == name }
          if name == "p" || name == "br"
            append_node(make_node(XML::Element, XML::Node::ELEMENT_NODE, name))
          else
            open = @stack.last
            if open
              error(
                %(The element type "#{open.name}" must be terminated by the matching end-tag "</#{open.name}>".),
                level: nil,
                location: false,
              )
            else
              error("Opening and ending tag mismatch: #{name}")
            end
          end
          return
        end
        if @stack.empty? || @stack.last.name != name
          open = @stack.last
          if open
            error(
              %(The element type "#{open.name}" must be terminated by the matching end-tag "</#{open.name}>".),
              level: nil,
              location: false,
            )
          else
            error("Opening and ending tag mismatch: #{name}")
          end
          while @stack.any? && @stack.last.name != name
            @stack.pop
            @scopes.pop if @scopes.length > 1
          end
        end
        return unless @stack.last&.name == name

        @stack.pop
        @scopes.pop if @scopes.length > 1
      end

      def read_comment
        advance("<!--")
        body = +""
        closed = false
        until @scanner.eos?
          if @scanner.check(/-->/)
            advance("-->")
            closed = true
            break
          end
          body << take_char
        end
        return if html_document? && !closed

        XML::Comment.new(@document, body)
      end

      def read_cdata
        advance("<![CDATA[")
        body = +""
        until @scanner.eos?
          if @scanner.check(/\]\]>/)
            advance("]]>")
            break
          end
          body << take_char
        end
        XML::CDATA.new(@document, body)
      end

      def read_pi
        advance("<?")
        target = read_name
        error("XML declaration allowed only at the start of the document") if target == "xml"
        error("xmlParsePI : no target name") if target.empty?
        skip_space
        body = +""
        until @scanner.eos?
          if @scanner.check(/\?>/)
            advance("?>")
            break
          end
          body << take_char
        end
        return if target.empty?

        XML::ProcessingInstruction.new(@document, target, body)
      end

      def read_doctype
        advance("<!DOCTYPE")
        skip_space
        name = read_name
        skip_space
        external_id = nil
        system_id = nil
        if @scanner.check(/PUBLIC/)
          advance("PUBLIC")
          skip_space
          external_id = read_quoted
          skip_space
          system_id = read_quoted if @scanner.check(/['"]/)
        elsif @scanner.check(/SYSTEM/)
          advance("SYSTEM")
          skip_space
          system_id = read_quoted
        end
        skip_space
        dtd = build_dtd(name, external_id, system_id)
        parse_internal_subset(dtd) if @scanner.check(/\[/)
        if load_external_subset? && system_id
          external = build_dtd(name, external_id, system_id)
          @document.pure.external_subset = external
          load_external_declarations(external, system_id, document_base)
        end
        skip_space
        expect(">")
        dtd
      end

      def build_dtd(name, external_id, system_id)
        dtd = XML::DTD.allocate
        State.attach(
          dtd,
          type: XML::Node::DTD_NODE,
          name: name,
          document: @document,
          external_id: external_id,
          system_id: system_id,
        )
        dtd
      end

      def load_external_subset?
        (@options & (XML::ParseOptions::DTDLOAD | XML::ParseOptions::DTDVALID)) != 0
      end

      def parse_internal_subset(dtd)
        advance("[")
        parse_declarations(dtd, document_base)
        advance("]") if @scanner.check(/\]/)
      end

      def parse_declarations(dtd, base)
        until @scanner.eos? || @scanner.check(/\]/)
          skip_space
          break if @scanner.eos? || @scanner.check(/\]/)

          if @scanner.check(/<!--/)
            read_comment
          elsif @scanner.check(/<\?/)
            read_pi
          elsif @scanner.check(/<!ENTITY/)
            read_entity_declaration(dtd, base)
          elsif @scanner.check(/<!ELEMENT/)
            read_element_declaration(dtd)
          elsif @scanner.check(/<!ATTLIST/)
            read_attlist_declaration(dtd)
          elsif @scanner.check(/<!NOTATION/)
            read_notation_declaration(dtd)
          elsif @scanner.check(/<!/)
            skip_declaration
          else
            break
          end
        end
      end

      def load_external_declarations(dtd, system_id, base)
        path = resolve_system_path(system_id, base)
        return unless path

        saved = [@scanner, @line, @column]
        @scanner = StringScanner.new(File.read(path))
        @line = 1
        @column = 1
        parse_declarations(dtd, path)
      ensure
        @scanner, @line, @column = saved if saved
      end

      def read_entity_declaration(dtd, base)
        advance("<!ENTITY")
        skip_space
        parameter = false
        if @scanner.check(/%/)
          advance("%")
          parameter = true
          skip_space
        end
        name = read_name
        skip_space
        if @scanner.check(/PUBLIC/)
          advance("PUBLIC")
          skip_space
          external_id = read_quoted
          skip_space
          system_id = read_quoted if @scanner.check(/['"]/)
          ndata = read_ndata
          add_entity(dtd, name, XML::EntityDecl::EXTERNAL_GENERAL_UNPARSED, external_id, system_id, nil, base) if !parameter && ndata
          add_entity(dtd, name, XML::EntityDecl::EXTERNAL_GENERAL_PARSED, external_id, system_id, nil, base) if !parameter && ndata.nil?
        elsif @scanner.check(/SYSTEM/)
          advance("SYSTEM")
          skip_space
          system_id = read_quoted
          ndata = read_ndata
          type = ndata ? XML::EntityDecl::EXTERNAL_GENERAL_UNPARSED : XML::EntityDecl::EXTERNAL_GENERAL_PARSED
          add_entity(dtd, name, type, nil, system_id, nil, base) unless parameter
        else
          value = read_quoted
          add_entity(dtd, name, XML::EntityDecl::INTERNAL_GENERAL, nil, nil, value, base) unless parameter
        end
        skip_space
        expect(">")
      end

      def read_ndata
        skip_space
        return unless @scanner.check(/NDATA/)

        advance("NDATA")
        skip_space
        read_name
      end

      def add_entity(dtd, name, type, external_id, system_id, value, base)
        return if name.empty? || dtd.entities.key?(name)

        node = XML::EntityDecl.allocate
        State.attach(
          node,
          type: XML::Node::ENTITY_DECL,
          name: name,
          document: @document,
          content: value,
          external_id: external_id,
          system_id: system_id,
        )
        node.instance_variable_set(:@entity_type, type)
        node.instance_variable_set(:@entity_base, base)
        dtd.add_child_node(node)
      end

      def read_element_declaration(dtd)
        advance("<!ELEMENT")
        skip_space
        name = read_name
        skip_space
        model = read_model
        node = XML::ElementDecl.allocate
        State.attach(
          node,
          type: XML::Node::ELEMENT_DECL,
          name: name,
          document: @document,
        )
        node.instance_variable_set(:@element_type, element_type_code(model))
        node.instance_variable_set(:@content_model, model)
        node.instance_variable_set(:@element_content, build_element_content(model))
        (dtd.instance_variable_get(:@attrs_for) || {})[name]&.each do |attr|
          node.pure.attributes << attr
        end
        dtd.add_child_node(node)
        skip_space
        expect(">")
      end

      def read_model
        return "" if @scanner.eos?

        if @scanner.check(/EMPTY|ANY/)
          token = @scanner.check(/EMPTY|ANY/)
          advance(token)
          return token
        end

        model = +""
        depth = 0
        until @scanner.eos?
          break if depth.zero? && @scanner.check(/>/)

          char = take_char
          model << char
          depth += 1 if char == "("
          depth -= 1 if char == ")"
        end
        model.strip
      end

      def build_element_content(model)
        return if model.nil? || model.empty? || model == "EMPTY" || model == "ANY"

        ContentModel.parse(@document, model)
      end

      def element_type_code(model)
        case model
        when "EMPTY" then 1
        when "ANY" then 2
        else
          model.include?("#PCDATA") ? 3 : 4
        end
      end

      def read_attlist_declaration(dtd)
        advance("<!ATTLIST")
        skip_space
        element_name = read_name
        skip_space
        until @scanner.eos? || @scanner.check(/>/)
          attr_name = read_name
          break if attr_name.empty?

          skip_space
          if @scanner.check(/\(/)
            enumeration = read_enumeration
            attr_type = "ENUMERATION"
          else
            attr_type = read_name
            enumeration = []
          end
          skip_space
          default = read_attr_default
          add_attribute_decl(dtd, element_name, attr_name, attr_type, default, enumeration)
          skip_space
        end
        expect(">")
      end

      def read_enumeration
        advance("(")
        values = []
        until @scanner.eos?
          skip_space
          break if @scanner.check(/\)/)

          token = @scanner.check(/[^)|]+/)
          values << token.strip if token
          advance(token) if token
          skip_space
          advance("|") if @scanner.check(/\|/)
        end
        advance(")") if @scanner.check(/\)/)
        values
      end

      def read_attr_default
        if @scanner.check(/#/)
          advance("#")
          token = read_name
          skip_space
          return read_quoted if @scanner.check(/['"]/)

          return nil if token == "IMPLIED" || token == "REQUIRED"

          return nil
        end
        read_quoted if @scanner.check(/['"]/)
      end

      def add_attribute_decl(dtd, element_name, name, attr_type, default, enumeration)
        node = XML::AttributeDecl.allocate
        State.attach(
          node,
          type: XML::Node::ATTRIBUTE_DECL,
          name: name,
          document: @document,
          content: default,
        )
        node.instance_variable_set(:@attribute_type, attr_type)
        node.instance_variable_set(:@default_value, default)
        node.instance_variable_set(:@enumeration, enumeration)
        node.instance_variable_set(:@owner_element, element_name)
        dtd.add_child_node(node)
        attrs = dtd.instance_variable_get(:@attrs_for) || {}
        (attrs[element_name] ||= []) << node
        dtd.instance_variable_set(:@attrs_for, attrs)
        element = dtd.pure.children.find { |child| child.node_type == XML::Node::ELEMENT_DECL && child.name == element_name }
        element.pure.attributes << node if element
      end

      def read_notation_declaration(dtd)
        advance("<!NOTATION")
        skip_space
        name = read_name
        skip_space
        public_id = nil
        system_id = nil
        if @scanner.check(/PUBLIC/)
          advance("PUBLIC")
          skip_space
          public_id = read_quoted
          skip_space
          system_id = read_quoted if @scanner.check(/['"]/)
        elsif @scanner.check(/SYSTEM/)
          advance("SYSTEM")
          skip_space
          system_id = read_quoted
        end
        skip_space
        expect(">")
        notations = dtd.instance_variable_get(:@notations) || {}
        notations[name] ||= XML::Notation.new(name, public_id, system_id)
        dtd.instance_variable_set(:@notations, notations)
      end

      def skip_declaration
        advance("<!")
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

      def html_document?
        @document.respond_to?(:html?) && @document.html?
      end

      def void_html?(name)
        return false unless html_document?

        HTML4::ElementDescription[name]&.empty?
      end

      def ensure_html_tree
        return unless html_document? && @root.document?

        elements = @document.pure.children.select(&:element?)
        return if elements.any? { |node| node.name.casecmp?("html") }

        html = XML::Element.new("html", @document)
        body = XML::Element.new("body", @document)
        movable = @document.pure.children.reject { |node| node.node_type == XML::Node::DTD_NODE }
        movable.each do |node|
          node.unlink
          node.pure.parent = body
          body.pure.children << node
        end
        body.pure.parent = html
        html.pure.children << body
        html.pure.parent = @document
        @document.pure.children << html
      end

      def apply_namespaces(element, qname, attributes)
        unless html_document?
          attributes.each do |attr_name, value|
            if attr_name == "xmlns"
              element.add_namespace_definition(nil, value)
            elsif attr_name.start_with?("xmlns:")
              element.add_namespace_definition(attr_name.split(":", 2).last, value)
            end
          end

          prefix, local = split_name(qname)
          if prefix
            ns = find_namespace(prefix, element)
            if ns
              element.pure.name = local
              element.pure.namespace = ns
            end
          else
            default_ns = find_namespace(nil, element)
            element.pure.namespace = default_ns if default_ns
          end
        end

        attributes.each do |attr_name, value|
          next if !html_document? && (attr_name == "xmlns" || attr_name.start_with?("xmlns:"))

          if html_document?
            attr = make_node(XML::Attr, XML::Node::ATTRIBUTE_NODE, attr_name.downcase, value&.to_s)
            attr.pure.parent = element
            element.pure.attributes << attr
            next
          end

          attr_prefix, attr_local = split_name(attr_name)
          attr = make_node(
            XML::Attr,
            XML::Node::ATTRIBUTE_NODE,
            attr_prefix ? attr_local : attr_name,
            value&.to_s,
          )
          attr.pure.parent = element
          if attr_prefix
            ns = find_namespace(attr_prefix, element)
            attr.pure.namespace = ns if ns
            element.pure.lang = value if attr_prefix == "xml" && attr_local == "lang"
          end
          element.pure.attributes << attr
        end
      end

      def find_namespace(prefix, element)
        element.namespace_definitions.each do |ns|
          return ns if ns.prefix == prefix
        end
        @scopes.reverse_each do |scope|
          scope.each do |ns|
            return ns if ns.prefix == prefix
          end
        end
        return @document.xml_namespace if prefix == "xml"

        nil
      end

      def inherited_scopes(context)
        return [] unless context.respond_to?(:namespace_scopes)

        context.namespace_scopes
      end

      def append_node(node)
        return if node.nil?

        state = node.instance_variable_get(:@pure)
        parent = @stack.last || @root
        return parent.add_child_node(node) unless state

        text_node = XML::Node::TEXT_NODE
        return if @root.document? && state.type == text_node && node.blank? && @stack.empty?

        # Parser nodes are new. Skip the cycle check and the unlink.
        if state.parent || !state.children.empty?
          parent.add_child_node(node)
          return
        end

        parent_state = parent.instance_variable_get(:@pure)
        if state.type == text_node
          last = parent_state.children.last
          if last
            last_state = last.instance_variable_get(:@pure)
            if last_state&.type == text_node
              extra = state.content.to_s
              current = last_state.content
              if current.is_a?(String) && !current.frozen?
                current << extra
              else
                last_state.content = current.to_s + extra
              end
              return
            end
          end
        end

        state.parent = parent
        state.document = parent_state.document
        parent_state.children << node
        node.decorate!
        # apply_namespaces already bound this element's namespaces. A second
        # adopt_namespaces walk repeats that search for every element.
      end

      def make_node(klass, type, name, content = nil, line = nil)
        node = klass.allocate
        Pure::State.fast_attach(node, type, name, @document, content, line)
        node
      end

      def append_text(text)
        return if text.empty?
        if @root.document? && @stack.empty?
          error("Start tag expected, '<' not found") unless text.match?(/\A\s*\z/)
          return
        end

        unless text.include?("&")
          append_node(make_node(XML::Text, XML::Node::TEXT_NODE, "text", text, @line))
          return
        end

        split_text_and_entities(text).each do |piece|
          node = piece.is_a?(XML::Node) ? piece : make_node(XML::Text, XML::Node::TEXT_NODE, "text", piece, @line)
          append_node(node)
        end
      end

      def split_text_and_entities(text)
        pieces = []
        buffer = +""
        scanner = StringScanner.new(text)
        until scanner.eos?
          if (literal = scanner.scan(/[^&]+/))
            buffer << literal
          elsif (ref = scanner.scan(/&(?:#\d+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9.-]*);/))
            name = ref[1..-2]
            if name.start_with?("#") || Entities::PREDEFINED.key?(name)
              buffer << Entities.decode_predefined(ref)
            elsif (entity = lookup_entity(name))
              pieces << buffer unless buffer.empty?
              buffer = +""
              pieces.concat(entity_reference_nodes(name, entity))
            else
              pieces << buffer unless buffer.empty?
              buffer = +""
              error("Entity '#{name}' not defined")
              pieces << XML::EntityReference.new(@document, name) unless noent?
            end
          else
            buffer << scanner.getch
          end
        end
        pieces << buffer unless buffer.empty?
        pieces
      end

      def read_until_markup
        string = @scanner.string
        pos = @scanner.pos
        found = string.byteindex("<", pos)
        unless found
          rest = string.byteslice(pos..) || +""
          @scanner.terminate
          account_text(rest)
          return rest
        end

        @scanner.pos = found
        return "" if found == pos

        text = string.byteslice(pos, found - pos)
        account_text(text)
        text
      end

      def read_attributes
        attributes = {}
        loop do
          skip_space
          byte = @scanner.string.getbyte(@scanner.pos)
          break if @scanner.eos? || byte == 62 || byte == 47

          name = read_name
          break if name.empty?

          skip_space
          if html_document? && @scanner.string.getbyte(@scanner.pos) != 61
            attributes[name] = ""
            next
          end
          expect("=")
          skip_space
          attributes[name] = read_attribute_value
        end
        attributes
      end

      def read_attribute_value
        return read_quoted if @scanner.check(/['"]/)
        return read_unquoted if html_document?

        read_quoted
      end

      def read_unquoted
        value = @scanner.scan(UNQUOTED) || ""
        account_text(value)
        value
      end

      def read_quoted
        quote = take_char
        unless quote == '"' || quote == "'"
          error("AttValue: \" or ' expected")
          return ""
        end
        pattern = quote == '"' ? QUOTED_DQ : QUOTED_SQ
        value = +""
        until @scanner.eos?
          run = @scanner.scan(pattern)
          if run
            value << run
            account_text(run)
            next
          end

          char = take_char
          break if char == quote

          if char == "&" && (!html_document? || @scanner.check(AMP_START))
            ref = +char
            until @scanner.eos?
              next_char = take_char
              ref << next_char
              break if next_char == ";"
            end
            value << decode_attribute_entity(ref)
          else
            value << char
          end
        end
        value
      end

      def decode_attribute_entity(ref)
        name = ref[1..-2]
        if name.nil?
          ref
        elsif name.start_with?("#") || Entities::PREDEFINED.key?(name)
          Entities.decode_predefined(ref)
        elsif (entity = lookup_entity(name))
          entity_text(entity)
        else
          error("Entity '#{name}' not defined")
          ref
        end
      end

      def noent?
        @options & XML::ParseOptions::NOENT != 0
      end

      def document_base
        url = @document.url
        return if url.nil? || url.empty?

        url
      end

      def lookup_entity(name)
        subset = @document.internal_subset
        found = subset.entities[name] if subset
        return found if found

        subset = @document.external_subset
        subset.entities[name] if subset
      end

      def entity_reference_nodes(name, entity)
        if entity_external?(entity)
          if noent? && entity.entity_type == XML::EntityDecl::EXTERNAL_GENERAL_PARSED
            nodes_from_entity_text(load_entity_source(entity).to_s)
          elsif noent?
            []
          else
            [XML::EntityReference.new(@document, name)]
          end
        elsif noent?
          nodes_from_entity_text(entity.content.to_s)
        else
          [XML::EntityReference.new(@document, name)]
        end
      end

      def entity_external?(entity)
        entity.entity_type != XML::EntityDecl::INTERNAL_GENERAL
      end

      def entity_text(entity)
        if entity_external?(entity)
          return "" unless noent? && entity.entity_type == XML::EntityDecl::EXTERNAL_GENERAL_PARSED

          load_entity_source(entity).to_s
        else
          entity.content.to_s
        end
      end

      def nodes_from_entity_text(text)
        return [] if text.empty?

        open = open_entities
        return [] if open.include?(text)

        open << text
        stripped = text.sub(/\A\s*<\?xml[^?]*\?>/, "")
        Parser.parse_fragment(@document, stripped, @stack.last, @options)
      ensure
        open&.pop
      end

      def open_entities
        list = @document.instance_variable_get(:@pure_open_entities)
        return list if list

        @document.instance_variable_set(:@pure_open_entities, [])
      end

      def load_entity_source(entity)
        resolve_system_path(entity.system_id, entity.instance_variable_get(:@entity_base))&.then { |path| File.read(path) }
      end

      def resolve_system_path(system_id, base)
        return if system_id.nil? || system_id.empty?
        return if system_id.match?(/\A[a-z][a-z0-9+.-]*:/i)

        if system_id.start_with?("/")
          return system_id if File.file?(system_id)

          return
        end
        return unless base

        directory = File.directory?(base) ? base : File.dirname(base)
        candidate = File.expand_path(system_id, directory)
        candidate if File.file?(candidate)
      end

      def record_validity_errors
        declared = {}
        [@document.internal_subset, @document.external_subset].compact.each do |subset|
          subset.elements.each_key { |name| declared[name] = true }
        end
        seen_attributes = {}
        each_validity_element(@document) do |element|
          known = declared[element.name]
          error("No declaration for element #{element.name}", level: 2) unless known
          element.pure.attributes.each do |attr|
            next if known
            next if seen_attributes[attr.name]

            seen_attributes[attr.name] = true
            error("No declaration for attribute #{attr.name} of element #{element.name}", level: 2)
          end
        end
      end

      def each_validity_element(node, &block)
        node.pure.children.each do |child|
          if child.element?
            yield child
            each_validity_element(child, &block)
          elsif child.node_type == XML::Node::ENTITY_REF_NODE
            entity = lookup_entity(child.name)
            next unless entity && !entity_external?(entity)

            nodes_from_entity_text(entity.content.to_s).each do |replacement|
              next unless replacement.element?

              yield replacement
              each_validity_element(replacement, &block)
            end
          end
        end
      end

      def read_name
        skip_space
        match = @scanner.check(NAME)
        return "" unless match

        advance(match)
        match
      end

      def split_name(qname)
        return [nil, qname] unless qname.include?(":")

        qname.split(":", 2)
      end

      def local_name(qname)
        _prefix, local = split_name(qname)
        local
      end

      def skip_space
        spaces = @scanner.scan(SPACE_RUN)
        account_text(spaces) if spaces
      end

      def skip_through(token)
        chunk = @scanner.scan_until(token_pattern(token))
        unless chunk
          rest = @scanner.rest
          @scanner.terminate
          account_text(rest)
          return
        end

        account_text(chunk)
      end

      def expect(token)
        return if advance(token)

        error("expected #{token.inspect}")
      end

      def advance(token)
        return false unless @scanner.peek(token.length) == token

        @scanner.pos += token.bytesize
        account_text(token)
        true
      end

      def token_pattern(token)
        @token_patterns ||= {}
        @token_patterns[token] ||= Regexp.new(Regexp.escape(token))
      end

      def account_text(string)
        return if string.nil? || string.empty?

        newlines = string.count("\n")
        if newlines.zero?
          @column += string.length
        else
          @line += newlines
          @column = string.length - string.rindex("\n")
        end
      end

      def take_char
        char = @scanner.getch
        return nil unless char

        if char == "\n"
          @line += 1
          @column = 1
        else
          @column += 1
        end
        char
      end

      def strict?
        @options & RECOVER == 0
      end

      def error(message, level: 3, location: true)
        syntax = XML::SyntaxError.new(message)
        if location
          syntax.instance_variable_set(:@line, @line)
          syntax.instance_variable_set(:@column, @column)
        end
        syntax.instance_variable_set(:@level, level)
        @document.errors << syntax
      end
    end

    # Binary content-model tree for an ELEMENT declaration.
    class ContentModel
      def self.parse(document, model)
        new(document, model).parse_particle
      end

      def initialize(document, model)
        @document = document
        @scanner = StringScanner.new(model.strip)
      end

      def parse_particle
        skip_space
        if @scanner.scan(/\(/)
          node = parse_group
          skip_space
          @scanner.scan(/\)/)
          node.instance_variable_set(:@occur, occurrence)
          node
        elsif @scanner.scan(/#PCDATA/)
          content_node(XML::ElementContent::PCDATA, "#PCDATA", nil, occurrence)
        else
          token = @scanner.scan(/[A-Za-z_:][\w:.-]*/)
          prefix, local = split_name(token.to_s)
          content_node(XML::ElementContent::ELEMENT, local, prefix, occurrence)
        end
      end

      private

      def parse_group
        first = parse_particle
        skip_space
        if @scanner.check(/,/)
          chain(first, XML::ElementContent::SEQ, /,/)
        elsif @scanner.check(/\|/)
          chain(first, XML::ElementContent::OR, /\|/)
        else
          first
        end
      end

      def chain(first, type, separator)
        items = [first]
        while @scanner.scan(separator)
          items << parse_particle
          skip_space
        end
        items.reverse.reduce do |right, left|
          node = content_node(type, nil, nil, XML::ElementContent::ONCE)
          node.instance_variable_set(:@c1, left)
          node.instance_variable_set(:@c2, right)
          node
        end
      end

      def content_node(type, name, prefix, occur)
        node = XML::ElementContent.allocate
        node.instance_variable_set(:@document, @document)
        node.instance_variable_set(:@type, type)
        node.instance_variable_set(:@name, name)
        node.instance_variable_set(:@prefix, prefix)
        node.instance_variable_set(:@occur, occur)
        node
      end

      def occurrence
        skip_space
        case @scanner.scan(/[?*+]/)
        when "?" then XML::ElementContent::OPT
        when "*" then XML::ElementContent::MULT
        when "+" then XML::ElementContent::PLUS
        else XML::ElementContent::ONCE
        end
      end

      def split_name(token)
        return [nil, token] unless token.include?(":")

        prefix, local = token.split(":", 2)
        [prefix, local]
      end

      def skip_space
        @scanner.skip(/\s+/)
      end
    end
  end
end
