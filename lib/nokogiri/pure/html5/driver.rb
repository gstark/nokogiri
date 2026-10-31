# frozen_string_literal: true

require_relative "lex"
require_relative "model"
require_relative "quirks"
require_relative "tree_builder"

module Nokogiri
  module Pure
    module Html5
      # Turns a Gumbo-shaped tree into Nokogiri nodes.
      #
      # A doctype is stored on the document, then the other document children are
      # appended. That keeps the doctype first, matching libxml's html document.
      module Driver
        ATTR_NS = {
          xlink: [XLINK_NS, "xlink"],
          xml: [XML_NS, "xml"],
          xmlns: [XMLNS_NS, "xmlns"]
        }.freeze

        ELEMENT_NS = {
          svg: [SVG_NS, "svg"],
          mathml: [MATHML_NS, "math"]
        }.freeze

        XHTML_NS = HTML_NS

        module_function

        def parse(string, url, klass, **options)
          document = klass.new_without_dtd
          document.send(:initialize)
          result = build(string, options, document)
          unless slot(result, :attached)
            source = slot(result, :document)
            install_doctype(document, source)
            add_nodes(document, children_of(source), document, nil)
          end
          finish(document, result, url)
          document
        end

        def fragment(owner, string, context, **options)
          tag, namespace, encoding, form = context_parts(owner, context)
          depth = options[:max_tree_depth]
          depth = depth.nil? ? Gumbo::DEFAULT_MAX_TREE_DEPTH : Integer(depth)
          depth += 1 if depth >= 0
          result = build(
            string,
            options.merge(
              max_tree_depth: depth,
              fragment_context: tag,
              fragment_namespace: namespace,
              fragment_encoding: encoding,
              quirks_mode: fragment_quirks(owner, context),
              fragment_context_has_form_ancestor: form
            ),
            owner
          )
          unless slot(result, :attached)
            root = slot(result, :root) || slot(result, :document)
            add_nodes(owner, children_of(root), owner, nil)
          end
          finish(owner, result, "#fragment")
          nil
        end

        PARSE_KEYS = %i[
          max_attributes max_errors max_tree_depth parse_noscript_content_as_text
          fragment_context fragment_namespace fragment_encoding quirks_mode
          fragment_context_has_form_ancestor
        ].freeze

        def build(string, options, parent = nil)
          unknown = options.keys.map(&:to_sym) - PARSE_KEYS
          raise ArgumentError, "unknown keyword: :#{unknown.first}" unless unknown.empty?

          native = rust_html5(string, options, parent)
          result = native || TreeBuilder.parse(
            string.to_s,
            max_attributes: integer_option(options, :max_attributes, Gumbo::DEFAULT_MAX_ATTRIBUTES),
            max_errors: integer_option(options, :max_errors, Gumbo::DEFAULT_MAX_ERRORS),
            max_tree_depth: integer_option(options, :max_tree_depth, Gumbo::DEFAULT_MAX_TREE_DEPTH),
            parse_noscript_content_as_text: options[:parse_noscript_content_as_text] ? true : false,
            fragment_context: options[:fragment_context],
            fragment_namespace: options[:fragment_namespace],
            fragment_encoding: options[:fragment_encoding],
            quirks_mode: options[:quirks_mode],
            fragment_context_has_form_ancestor: options[:fragment_context_has_form_ancestor] ? true : false
          )
          raise_limit!(result)
          result[:input] = string.to_s if result[:input].nil?
          result
        end

        # One native call builds the tree and links the nodes. Nil keeps the Ruby builder.
        def rust_html5(string, options, parent)
          return nil if ENV["NOKOGIRI_RUST_HTML5"] == "0"
          return nil unless defined?(Nokogiri::Pure::RustHtml5) && Nokogiri::Pure::RustHtml5.respond_to?(:tree)

          context = options[:fragment_context]
          namespace = options[:fragment_namespace]
          encoding = options[:fragment_encoding]
          packed = [
            integer_option(options, :max_attributes, Gumbo::DEFAULT_MAX_ATTRIBUTES),
            integer_option(options, :max_errors, Gumbo::DEFAULT_MAX_ERRORS),
            integer_option(options, :max_tree_depth, Gumbo::DEFAULT_MAX_TREE_DEPTH),
            options[:parse_noscript_content_as_text] ? 1 : 0,
            context&.to_s,
            namespace&.to_s,
            encoding&.to_s,
            options[:quirks_mode].nil? ? 0 : Integer(options[:quirks_mode]),
            options[:fragment_context_has_form_ancestor] ? 1 : 0
          ]
          result = Nokogiri::Pure::RustHtml5.tree(string.to_s, packed, parent)
          result if result.is_a?(Hash)
        end

        def integer_option(options, key, default)
          value = options.fetch(key, default)
          value.nil? ? default : Integer(value)
        end

        def raise_limit!(result)
          status = result[:status] || result["status"]
          return if status.nil? || status == :ok || status == "ok"

          message = result[:status_message] || result[:message]
          message ||= case status.to_sym
          when :too_many_attributes
            "Attributes per element limit exceeded"
          when :tree_too_deep
            "Document tree depth limit exceeded"
          else
            status.to_s
          end
          raise ArgumentError, message
        end

        def install_doctype(document, source)
          return unless source

          if field(source, :has_doctype)
            document.create_internal_subset(
              field(source, :doctype_name).to_s,
              blank_to_nil(field(source, :public_id)),
              blank_to_nil(field(source, :system_id))
            )
            return
          end

          doctype = children_of(source).find { |child| node_type(child) == :doctype }
          return unless doctype

          document.create_internal_subset(
            text_of(doctype),
            blank_to_nil(field(doctype, :public_id)),
            blank_to_nil(field(doctype, :system_id))
          )
        end

        def blank_to_nil(value)
          return if value.nil? || value.to_s.empty?

          value.to_s
        end

        def finish(node, result, file)
          document = slot(result, :document)
          quirks = slot(result, :quirks_mode)
          quirks = field(document, :quirks_mode) if quirks.nil? && document
          node.instance_variable_set(:@quirks_mode, quirks || Quirks::NO_QUIRKS)
          node.instance_variable_set(:@url, file) if node.respond_to?(:url) && !file.nil? && file != "#fragment"
          node.instance_variable_set(:@errors, syntax_errors(slot(result, :errors), slot(result, :input) || "", file))
        end

        # The Ruby builder uses symbol keys. The native builder uses string keys.
        def slot(result, key)
          return if result.nil?
          return result.public_send(key) if result.respond_to?(key) && !result.is_a?(Hash)
          return unless result.is_a?(Hash)
          return result[key] if result.key?(key)

          result[key.to_s] if result.key?(key.to_s)
        end

        def syntax_errors(errors, source, file)
          Array(errors).map do |error|
            line = field(error, :line) || 0
            column = field(error, :column) || 0
            message = caret(field(error, :message).to_s, source, field(error, :byte_offset), column)
            syntax = XML::SyntaxError.new(message)
            syntax.instance_variable_set(:@domain, 1)
            syntax.instance_variable_set(:@code, 1)
            syntax.instance_variable_set(:@level, 2)
            syntax.instance_variable_set(:@file, file)
            syntax.instance_variable_set(:@line, line)
            syntax.instance_variable_set(:@column, column)
            syntax.instance_variable_set(:@str1, field(error, :code)&.to_s)
            syntax.instance_variable_set(:@str2, nil)
            syntax.instance_variable_set(:@str3, nil)
            syntax.instance_variable_set(:@int1, 0)
            syntax
          end
        end

        def caret(message, source, byte_offset, column)
          return message if message.include?("\n")

          line = source_line(source.to_s, byte_offset)
          spaces = (column.to_i >= 2) ? " " * (column.to_i - 1) : ""
          "#{message}\n#{line}\n#{spaces}^\n"
        end

        def source_line(source, byte_offset)
          bytes = source.b
          limit = bytes.bytesize
          pos = byte_offset.to_i
          pos = 0 if pos.negative?
          pos = limit if pos > limit
          cursor = pos
          cursor -= 1 if cursor.positive? && (cursor == limit || bytes.getbyte(cursor) == 10)
          cursor -= 1 while cursor.positive? && bytes.getbyte(cursor) != 10
          start = cursor.zero? ? 0 : cursor + 1
          finish = pos
          finish += 1 while finish < limit && bytes.getbyte(finish) != 10
          bytes.byteslice(start, finish - start).force_encoding(Encoding::UTF_8)
        end

        def add_nodes(parent, nodes, output, anchor)
          nodes.each do |node|
            next if node_type(node) == :doctype

            anchor = add_node(parent, node, output, anchor)
            anchor = nil if parent.equal?(output)
          end
          anchor
        end

        def add_node(parent, node, output, anchor)
          case node_type(node)
          when :element, :template
            add_element(parent, node, output, anchor)
          when :text, :whitespace, :null
            add_text(parent, node, XML::Text, XML::Node::TEXT_NODE)
            anchor
          when :cdata
            add_text(parent, node, XML::CDATA, XML::Node::CDATA_SECTION_NODE)
            anchor
          when :comment
            add_text(parent, node, XML::Comment, XML::Node::COMMENT_NODE)
            anchor
          else
            anchor
          end
        end

        def add_element(parent, node, output, anchor)
          document = parent.document? ? parent : parent.document
          element = XML::Element.allocate
          Pure::State.fast_attach(
            element,
            XML::Node::ELEMENT_NODE,
            tag_name(node),
            document,
            nil,
            stored_line(field(node, :line))
          )
          anchor ||= element
          apply_element_namespace(element, anchor, document, field(node, :namespace))
          add_attributes(element, anchor, document, field(node, :attrs) || field(node, :attributes))
          parent.add_child_node(element)
          add_nodes(element, children_of(node), output, anchor)
          anchor
        end

        def add_text(parent, node, klass, type)
          document = parent.document? ? parent : parent.document
          text = klass.allocate
          Pure::State.fast_attach(text, type, leaf_name(type), document, text_of(node), stored_line(field(node, :line)))
          parent.add_child_node(text)
        end

        def leaf_name(type)
          case type
          when XML::Node::COMMENT_NODE then "comment"
          when XML::Node::CDATA_SECTION_NODE then "#cdata-section"
          else "text"
          end
        end

        def apply_element_namespace(element, anchor, document, namespace)
          pair = ELEMENT_NS[namespace_key(namespace)]
          return unless pair

          element.pure.namespace = declare(anchor, document, pair[1], pair[0])
        end

        def add_attributes(element, anchor, document, attrs)
          Array(attrs).each do |attr|
            name, value, namespace = attribute_parts(attr)
            node = XML::Attr.allocate
            Pure::State.fast_attach(node, XML::Node::ATTRIBUTE_NODE, name, document, value.to_s, nil)
            pair = ATTR_NS[namespace_key(namespace)]
            if pair
              node.pure.namespace = if pair[1] == "xml"
                document.xml_namespace
              else
                declare(anchor, document, pair[1], pair[0])
              end
            end
            node.pure.parent = element
            element.pure.attributes << node
          end
        end

        def declare(anchor, document, prefix, href)
          found = anchor.pure.namespace_definitions.find { |ns| ns.prefix == prefix && ns.href == href }
          return found if found

          created = XML::Namespace.new(document, prefix, href)
          anchor.pure.namespace_definitions << created
          created
        end

        def attribute_parts(attr)
          if attr.is_a?(Array)
            [attr[0].to_s, attr[1].to_s, attr[2]]
          else
            [field(attr, :name).to_s, field(attr, :value).to_s, field(attr, :namespace) || field(attr, :ns)]
          end
        end

        def namespace_key(namespace)
          return if namespace.nil?

          key = namespace.to_s
          return if key.empty? || key == "html" || key == XHTML_NS

          key = "mathml" if key == "math"
          key.to_sym
        end

        def children_of(node)
          return [] unless node

          list = field(node, :children)
          list || []
        end

        def node_type(node)
          value = field(node, :type)
          value.is_a?(Symbol) ? value : value.to_s.to_sym
        end

        def tag_name(node)
          (field(node, :name) || field(node, :tag)).to_s
        end

        def text_of(node)
          value = field(node, :content)
          value = field(node, :data) if value.nil?
          value = field(node, :name) if value.nil?
          value.to_s
        end

        def field(node, key)
          return if node.nil?
          return node.public_send(key) if node.respond_to?(key)
          return node[key] if node.is_a?(Hash) && node.key?(key)

          node[key.to_s] if node.is_a?(Hash)
        end

        def stored_line(line)
          number = line.to_i
          return if number <= 0 || number >= 65_535

          number
        end

        def context_parts(_owner, context)
          if context.nil?
            ["body", :html, nil, false]
          elsif context.is_a?(String)
            string_context(context)
          else
            node_context(context)
          end
        end

        def string_context(context)
          tag = context
          namespace = :html
          if (colon = context.index(":"))
            prefix = context.byteslice(0, colon)
            tag = context.byteslice(colon + 1, context.bytesize - colon - 1)
            namespace = context_namespace(prefix)
          elsif tag.length == 3 && tag.casecmp("svg").zero?
            namespace = :svg
          elsif tag.length == 4 && tag.casecmp("math").zero?
            namespace = :mathml
          end
          form = namespace == :html && tag.casecmp("form").zero?
          [tag, namespace, nil, form]
        end

        def context_namespace(prefix)
          if prefix.length == 3 && prefix.casecmp("svg").zero?
            :svg
          elsif prefix.length == 4 && prefix.casecmp("html").zero?
            :html
          elsif prefix.length == 4 && prefix.casecmp("math").zero?
            :mathml
          else
            raise ArgumentError, "Invalid context namespace '#{prefix}'"
          end
        end

        def node_context(context)
          tag = context.name.to_s
          namespace = namespace_of(context, true)
          encoding = nil
          if namespace == :mathml && tag.length == 14 && tag.casecmp("annotation-xml").zero?
            value = context["encoding"]
            encoding = value.to_s if value
          end
          [tag, namespace, encoding, form_ancestor?(context)]
        end

        def namespace_of(node, required)
          href = node.namespace&.href
          return :html if href.nil? || href == XHTML_NS
          return :mathml if href == MATHML_NS
          return :svg if href == SVG_NS
          return :html unless required

          raise ArgumentError, "Unexpected namespace URI \"#{href}\""
        end

        def form_ancestor?(node)
          current = node
          while current
            if current.respond_to?(:element?) && current.element? && current.name.to_s.casecmp("form").zero?
              return true if namespace_of(current, false) == :html
            end
            break unless current.respond_to?(:parent)

            current = current.parent
          end
          false
        end

        def fragment_quirks(owner, context)
          document = owner.document
          return Quirks::NO_QUIRKS if context.nil? || context.is_a?(String) || document.quirks_mode.nil?

          dtd = document.internal_subset
          return Quirks::QUIRKS unless dtd

          Quirks.compute(dtd.name, dtd.external_id, dtd.system_id, !dtd.system_id.nil?)
        end
      end
    end
  end
end
