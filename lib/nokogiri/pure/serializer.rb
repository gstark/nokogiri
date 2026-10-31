# frozen_string_literal: true

module Nokogiri
  module Pure
    # Writes a pure DOM node in the shape libxml produces for the default save options.
    class Serializer
      FORMAT = 1
      NO_DECLARATION = 2
      NO_EMPTY_TAGS = 4
      AS_XHTML = 16
      AS_XML = 32
      AS_HTML = 64
      # Document#to_html passes FORMAT | NO_DECLARATION | NO_EMPTY_TAGS | AS_HTML.
      HTML_DEFAULT = FORMAT | NO_DECLARATION | NO_EMPTY_TAGS | AS_HTML
      RAW_TEXT = {"script" => true, "style" => true}.freeze
      HTML_BOOLEAN = %w[
        checked compact declare defer disabled ismap multiple nohref noresize noshade nowrap
        readonly selected
      ].freeze

      def self.write(node, io, encoding, indentation, options)
        writer = new(indentation, options, encoding)
        writer.write(node)
        io.write(recode(writer.output, encoding))
      end

      def self.recode(text, encoding)
        return text if encoding.nil? || encoding.to_s.empty?

        target = Encoding.find(encoding.to_s)
        return text if target == Encoding::UTF_8

        text.encode(target)
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
        encode_with_entities(text, target)
      rescue ArgumentError, Encoding::ConverterNotFoundError
        text
      end

      # One pass replaces characters the target encoding cannot store.
      # A successful document encode does not call this method.
      def self.encode_with_entities(text, target)
        replaced = +""
        text.each_char do |char|
          char.encode(target)
          replaced << char
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
          replaced << "&##{char.ord};"
        end
        replaced.encode(target)
      rescue ArgumentError, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError, Encoding::ConverterNotFoundError
        text
      end
      private_class_method :encode_with_entities

      def initialize(indentation, options, encoding = nil)
        @output = +""
        @unit = indentation
        @options = options
        @encoding_name = encoding&.to_s
        @encoding_name = nil if @encoding_name && @encoding_name.empty?
        @target = resolve_target(encoding)
        @html_format = options & FORMAT != 0 && options & AS_HTML != 0 &&
          options & (AS_XHTML | AS_XML) == 0
      end

      def resolve_target(encoding)
        return if encoding.nil? || encoding.to_s.empty?

        target = Encoding.find(encoding.to_s)
        (target == Encoding::UTF_8) ? nil : target
      rescue ArgumentError, Encoding::ConverterNotFoundError
        nil
      end

      attr_reader :output

      def write(node)
        return if append_flat_xml(node)

        owner = node.document? ? node : node.document
        @html = !owner.nil? && owner.html?
        return if append_html_pieces(node)

        recording = record_html?(node)
        @pieces = [] if recording
        if node.document?
          write_document(node)
        else
          write_node(node, 0, node.next_sibling)
        end
        node.instance_variable_set(:@html_pieces, @pieces) if recording
        @pieces = nil
      end

      private

      # Default XML save of a flat document. Skip this when a caller has
      # materialized a node and changed it without retiring the table.
      def append_flat_xml(node)
        return false unless node.document?
        # Document#to_xml passes FORMAT. Node#to_xml passes FORMAT | AS_XML.
        # Both print the same XML when no other save bit is set.
        return false unless (@options & ~AS_XML) == FORMAT
        return false unless @target.nil?

        flat = node.instance_variable_get(:@flat)
        return false unless flat&.fresh_for_write?

        flat.append_default_xml(@output, node, @unit)
        true
      end

      # Default HTML save. The first call records each emitted piece. Later
      # calls copy those pieces. A tree edit removes @html_pieces.
      def append_html_pieces(node)
        return false unless @html && node.document?
        return false unless @options == HTML_DEFAULT && @target.nil?

        pieces = node.instance_variable_get(:@html_pieces)
        return false unless pieces

        index = 0
        length = pieces.length
        while index < length
          @output << pieces[index]
          index += 1
        end
        true
      end

      def record_html?(node)
        @html && node.document? && @options == HTML_DEFAULT && @target.nil?
      end

      def format?
        @options & FORMAT != 0
      end

      def suppress_declaration?(document)
        return true if @options & NO_DECLARATION != 0
        return false unless document.html?

        @options & AS_XML == 0 && @options & AS_XHTML == 0
      end

      def emit(string)
        text = string.to_s
        @output << text
        @pieces << text if @pieces
      end

      def write_document(document)
        unless suppress_declaration?(document)
          emit(%(<?xml version="#{document.version || "1.0"}"))
          encoding = document.encoding
          emit(%( encoding="#{encoding}")) if encoding && !encoding.empty?
          emit("?>")
          emit("\n") if format?
        end
        # The libxml2 HTML dumper ends each top-level node with a newline, also without FORMAT.
        newline = format? || (@html && @options & (AS_XHTML | AS_XML) == 0)
        document.pure.children.each do |child|
          write_node(child, 0)
          emit("\n") if newline
        end
      end

      def write_node(node, depth, following = nil)
        state = node.instance_variable_get(:@pure)
        case state.type
        when XML::Node::ELEMENT_NODE
          write_element(node, depth, state, following)
        when XML::Node::TEXT_NODE
          text = state.content.to_s
          raw = node.instance_variable_get(:@xslt_disable_output_escaping) || raw_text?(state)
          emit(raw ? text : Entities.escape_text(text))
        when XML::Node::CDATA_SECTION_NODE
          # The libxml2 HTML dumper writes CDATA content as is.
          if @html && @options & AS_XML == 0 && @options & AS_XHTML == 0
            emit(state.content.to_s)
          else
            emit("<![CDATA[#{state.content}]]>")
          end
        when XML::Node::COMMENT_NODE
          emit("<!--#{state.content}-->")
        when XML::Node::PI_NODE
          if state.content.to_s.empty?
            emit("<?#{state.name}?>")
          else
            emit("<?#{state.name} #{state.content}?>")
          end
        when XML::Node::DTD_NODE
          write_dtd(node)
        when XML::Node::ENTITY_REF_NODE
          emit("&#{state.name};")
        when XML::Node::ATTRIBUTE_NODE
          emit(attribute_text(node))
        when XML::Node::DOCUMENT_FRAG_NODE
          write_children(state.children, depth)
        else
          write_children(state.children, depth)
        end
      end

      def write_element(node, depth, state, following)
        name = qualified_name(state)
        emit("<#{name}")
        write_namespace_declarations(node)
        write_attributes(node)
        children = state.children
        block = @html_format && html_block?(state)
        if children.empty?
          if html_void?(state) && @options & AS_XML == 0
            emit((@options & AS_XHTML != 0) ? " />" : ">")
          elsif @options & NO_EMPTY_TAGS != 0 || @options & AS_HTML != 0 || @options & AS_XHTML != 0
            emit("></#{name}>")
          else
            emit("/>")
          end
        else
          emit(">")
          if format_children?(node)
            children.each do |child|
              emit("\n#{@unit * (depth + 1)}")
              write_node(child, depth + 1)
            end
            emit("\n#{@unit * depth}")
          else
            # libxml2 breaks the lines of a block element with more than one
            # child, unless its name starts with "p" (p, pre, param).
            wrap = block && children.length > 1 && !name.start_with?("p")
            emit("\n") if wrap && !inline_text?(children.first)
            write_children(children, depth + 1)
            emit("\n") if wrap && !inline_text?(children.last)
          end
          emit("</#{name}>")
        end
        emit("\n") if block && html_break_after?(state, following)
      end

      def write_children(children, depth)
        index = 0
        length = children.length
        while index < length
          write_node(children[index], depth, children[index + 1])
          index += 1
        end
      end

      def html_block?(state)
        return false unless state.namespace.nil?

        descriptions = HTML4::ElementDescription::DefaultDescriptions
        desc = descriptions[state.name] || descriptions[state.name.downcase]
        !desc.nil? && !desc.isinline
      end

      def inline_text?(node)
        type = node.node_type
        type == XML::Node::TEXT_NODE || type == XML::Node::ENTITY_REF_NODE
      end

      # libxml2 puts a new line after a block element when an element or
      # comment follows it, inside a parent whose name does not start with "p".
      def html_break_after?(state, following)
        return false if following.nil? || inline_text?(following)

        parent = state.parent&.instance_variable_get(:@pure)
        parent&.type == XML::Node::ELEMENT_NODE && !parent.name.to_s.start_with?("p")
      end

      def format_children?(node)
        return false unless format?
        return false if @options & AS_HTML != 0 && @options & AS_XHTML == 0 && @options & AS_XML == 0

        children = node.pure.children
        return false if children.empty?

        children.none? { |child| child.text? || child.cdata? || child.node_type == XML::Node::ENTITY_REF_NODE }
      end

      def write_namespace_declarations(node)
        node.pure.namespace_definitions.each do |ns|
          if ns.prefix.nil? || ns.prefix.empty?
            emit(%( xmlns="#{Entities.escape_attr(ns.href)}"))
          else
            emit(%( xmlns:#{ns.prefix}="#{Entities.escape_attr(ns.href)}"))
          end
        end
      end

      def write_attributes(node)
        node.pure.attributes.each do |attr|
          emit(" #{attribute_text(attr)}")
        end
      end

      def attribute_text(attr)
        state = attr.instance_variable_get(:@pure)
        prefix = state.namespace&.prefix
        name = if prefix && !prefix.empty?
          "#{prefix}:#{state.name}"
        else
          state.name
        end
        value = state.content.to_s
        return name if html_boolean?(state, value)

        value = charset_value(attr, state, value)
        escaped = Entities.escape_attr(value, percent_quotes: html_attribute_quoting?)
        %(#{name}="#{escaped}")
      end

      def html_void?(state)
        return false unless @html
        return false unless state.type == XML::Node::ELEMENT_NODE

        Parser.void_html_names[state.name]
      end

      def raw_text?(state)
        return false unless @html

        parent = state.parent
        parent_state = parent&.instance_variable_get(:@pure)
        return false unless parent_state&.type == XML::Node::ELEMENT_NODE

        name = parent_state.name.to_s
        RAW_TEXT[name] || RAW_TEXT[name.downcase]
      end

      def html_attribute_quoting?
        return false if @options & AS_XHTML != 0

        @options & AS_HTML != 0
      end

      def charset_value(_attr, state, value)
        return value unless @encoding_name
        return value unless @html

        parent_state = state.parent&.instance_variable_get(:@pure)
        return value unless parent_state&.type == XML::Node::ELEMENT_NODE
        return value unless parent_state.name.to_s.casecmp?("meta")

        if state.name.to_s.casecmp?("charset")
          @encoding_name
        elsif state.name.to_s.casecmp?("content") && value.to_s.match?(/charset\s*=/i)
          value.to_s.sub(/charset\s*=\s*[^;"'\s]+/i, "charset=#{@encoding_name}")
        else
          value
        end
      end

      def html_boolean?(state, value)
        return false unless @html
        return false unless value.nil? || value.empty?

        HTML_BOOLEAN.include?(state.name.to_s.downcase)
      end

      def write_dtd(node)
        emit("<!DOCTYPE #{node.name}")
        if node.external_id
          emit(%( PUBLIC "#{node.external_id}"))
          emit(%( "#{node.system_id}")) if node.system_id
        elsif node.system_id
          emit(%( SYSTEM "#{node.system_id}"))
        end
        emit(">")
      end

      def qualified_name(state)
        prefix = state.namespace&.prefix
        if prefix && !prefix.empty?
          "#{prefix}:#{state.name}"
        else
          state.name
        end
      end
    end
  end
end
