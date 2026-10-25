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
        case node.node_type
        when XML::Node::ELEMENT_NODE
          write_element(node, depth)
        when XML::Node::TEXT_NODE
          emit(raw_text?(node) ? node.content.to_s : Entities.escape_text(node.content))
        when XML::Node::CDATA_SECTION_NODE
          emit("<![CDATA[#{node.content}]]>")
        when XML::Node::COMMENT_NODE
          emit("<!--#{node.content}-->")
        when XML::Node::PI_NODE
          if node.content.empty?
            emit("<?#{node.name}?>")
          else
            emit("<?#{node.name} #{node.content}?>")
          end
        when XML::Node::DTD_NODE
          write_dtd(node)
        when XML::Node::ENTITY_REF_NODE
          emit("&#{node.name};")
        when XML::Node::ATTRIBUTE_NODE
          emit(attribute_text(node))
        when XML::Node::DOCUMENT_FRAG_NODE
          node.pure.children.each { |child| write_node(child, depth) }
        else
          node.pure.children.each { |child| write_node(child, depth) }
        end
      end

      def write_element(node, depth)
        emit("<#{qualified_name(node)}")
        write_namespace_declarations(node)
        write_attributes(node)
        children = node.pure.children
        if children.empty?
          if html_void?(node) && @options & AS_XML == 0
            emit(@options & AS_XHTML != 0 ? " />" : ">")
          elsif @options & NO_EMPTY_TAGS != 0 || @options & AS_HTML != 0 || @options & AS_XHTML != 0
            emit("></#{qualified_name(node)}>")
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
        emit("</#{qualified_name(node)}>")
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
        name = if attr.namespace&.prefix && !attr.namespace.prefix.empty?
          "#{attr.namespace.prefix}:#{attr.name}"
        else
          attr.name
        end
        return name if html_boolean?(attr)

        value = charset_value(attr, attr.value)
        escaped = Entities.escape_attr(value)
        escaped = escaped.gsub("&quot;", "%22") if html_attribute_quoting?
        %(#{name}="#{escaped}")
      end

      def html_void?(node)
        return false unless node.document&.html?
        return false unless node.element?

        HTML4::ElementDescription[node.name]&.empty?
      end

      def raw_text?(node)
        parent = node.parent
        return false unless parent&.element?
        return false unless parent.document&.html?

        RAW_TEXT.include?(parent.name.to_s.downcase)
      end

      def html_attribute_quoting?
        return false if @options & AS_XHTML != 0

        @options & AS_HTML != 0
      end

      def charset_value(attr, value)
        return value unless @encoding_name
        return value unless attr.parent&.element?
        return value unless attr.parent.document&.html?
        return value unless attr.parent.name.to_s.casecmp?("meta")

        if attr.name.to_s.casecmp?("charset")
          @encoding_name
        elsif attr.name.to_s.casecmp?("content") && value.to_s.match?(/charset\s*=/i)
          value.to_s.sub(/charset\s*=\s*[^;"'\s]+/i, "charset=#{@encoding_name}")
        else
          value
        end
      end

      def html_boolean?(attr)
        return false unless attr.document&.html?
        return false unless attr.value.nil? || attr.value.empty?

        HTML_BOOLEAN.include?(attr.name.to_s.downcase)
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

      def qualified_name(node)
        prefix = node.namespace&.prefix
        if prefix && !prefix.empty?
          "#{prefix}:#{node.name}"
        else
          node.name
        end
      end
    end
  end
end
