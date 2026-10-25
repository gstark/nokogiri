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
      RAW_TEXT = %w[script style].freeze
      HTML_BOOLEAN = %w[
        checked compact declare defer disabled ismap multiple nohref noresize noshade nowrap
        readonly selected
      ].freeze

      def self.write(node, io, encoding, indentation, options)
        buffer = StringIO.new(+"")
        new(buffer, indentation, options, encoding).write(node)
        io.write(recode(buffer.string, encoding))
      end

      def self.recode(text, encoding)
        return text if encoding.nil? || encoding.to_s.empty?

        target = Encoding.find(encoding.to_s)
        return text if target == Encoding::UTF_8

        text.encode(target)
      rescue ArgumentError, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError, Encoding::ConverterNotFoundError
        text
      end

      def initialize(io, indentation, options, encoding = nil)
        @io = io
        @unit = indentation
        @options = options
        @encoding_name = encoding&.to_s
        @encoding_name = nil if @encoding_name&.empty?
        @target = resolve_target(encoding)
      end

      def resolve_target(encoding)
        return if encoding.nil? || encoding.to_s.empty?

        target = Encoding.find(encoding.to_s)
        target == Encoding::UTF_8 ? nil : target
      rescue ArgumentError, Encoding::ConverterNotFoundError
        nil
      end

      def write(node)
        owner = node.document? ? node : node.document
        @html = !owner.nil? && owner.html?
        if node.document?
          write_document(node)
        else
          write_node(node, 0)
        end
      end

      private

      def format?
        @options & FORMAT != 0
      end

      def suppress_declaration?(document)
        return true if @options & NO_DECLARATION != 0
        return false unless document.html?

        @options & AS_XML == 0 && @options & AS_XHTML == 0
      end

      def emit(string)
        @io.write(prepare(string.to_s))
      end

      def prepare(string)
        return string if @target.nil?

        string.each_char.map do |char|
          char.encode(@target)
          char
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
          "&##{char.ord};"
        end.join
      end

      def write_document(document)
        unless suppress_declaration?(document)
          emit(%(<?xml version="#{document.version || "1.0"}"))
          encoding = document.encoding
          emit(%( encoding="#{encoding}")) if encoding && !encoding.empty?
          emit("?>")
          emit("\n") if format?
        end
        document.pure.children.each do |child|
          write_node(child, 0)
          emit("\n") if format?
        end
      end

      def write_node(node, depth)
        state = node.instance_variable_get(:@pure)
        case state.type
        when XML::Node::ELEMENT_NODE
          write_element(node, depth, state)
        when XML::Node::TEXT_NODE
          text = state.content.to_s
          emit(raw_text?(state) ? text : Entities.escape_text(text))
        when XML::Node::CDATA_SECTION_NODE
          emit("<![CDATA[#{state.content}]]>")
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
          state.children.each { |child| write_node(child, depth) }
        else
          state.children.each { |child| write_node(child, depth) }
        end
      end

      def write_element(node, depth, state)
        name = qualified_name(state)
        emit("<#{name}")
        write_namespace_declarations(node)
        write_attributes(node)
        children = state.children
        if children.empty?
          if html_void?(state) && @options & AS_XML == 0
            emit(@options & AS_XHTML != 0 ? " />" : ">")
          elsif @options & NO_EMPTY_TAGS != 0 || @options & AS_HTML != 0 || @options & AS_XHTML != 0
            emit("></#{name}>")
          else
            emit("/>")
          end
          return
        end

        emit(">")
        if format_children?(node)
          children.each do |child|
            emit("\n#{@unit * (depth + 1)}")
            write_node(child, depth + 1)
          end
          emit("\n#{@unit * depth}")
        else
          children.each { |child| write_node(child, depth + 1) }
        end
        emit("</#{name}>")
      end

      def format_children?(node)
        return false unless format?
        return false if @options & AS_HTML != 0 && @options & AS_XHTML == 0 && @options & AS_XML == 0

        children = node.pure.children
        return false if children.empty?

        children.none? { |child| child.text? || child.cdata? || child.node_type == XML::Node::ENTITY_REF_NODE }
      end

      def write_namespace_declarations(node)
        node.namespace_definitions.each do |ns|
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

        HTML4::ElementDescription[state.name]&.empty?
      end

      def raw_text?(state)
        return false unless @html

        parent = state.parent
        parent_state = parent&.instance_variable_get(:@pure)
        return false unless parent_state&.type == XML::Node::ELEMENT_NODE

        RAW_TEXT.include?(parent_state.name.to_s.downcase)
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
