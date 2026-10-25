# frozen_string_literal: true

module Nokogiri
  module Pure
    # Canonical XML 1.0, Canonical XML 1.1, and Exclusive Canonical XML 1.0.
    class C14n
      XML_HREF = "http://www.w3.org/XML/1998/namespace"

      def self.canonicalize(document, mode, inclusive_namespaces, with_comments, &block)
        new(document, mode, inclusive_namespaces, with_comments, block).canonicalize
      end

      def initialize(document, mode, inclusive_namespaces, with_comments, block)
        raise TypeError unless mode.nil? || mode.is_a?(Integer)
        raise TypeError unless inclusive_namespaces.nil? || inclusive_namespaces.is_a?(Array)

        @document = document
        @mode = mode || XML::XML_C14N_1_0
        if inclusive_namespaces && (@mode == XML::XML_C14N_1_0 || @mode == XML::XML_C14N_1_1)
          raise RuntimeError, "This canonicalizer does not support this operation"
        end
        @inclusive = inclusive_namespaces&.map { |prefix| prefix.to_str }
        @with_comments = with_comments
        @block = block
        @out = +""
        @rendered = []
      end

      def canonicalize
        @document.pure.children.each { |child| process_node(child) }
        @out
      end

      private

      def exclusive?
        @mode == XML::XML_C14N_EXCLUSIVE_1_0
      end

      def visible?(node, parent)
        return true unless @block

        result = @block.call(node, parent)
        !result.nil? && result != false
      end

      def process_node(node)
        shown = visible?(node, node.parent)
        case node.node_type
        when XML::Node::ELEMENT_NODE
          process_element(node, shown)
        when XML::Node::TEXT_NODE, XML::Node::CDATA_SECTION_NODE
          @out << escape_text(node.content) if shown
        when XML::Node::COMMENT_NODE
          @out << "<!--#{node.content}-->" if shown && @with_comments
        when XML::Node::PI_NODE
          write_pi(node) if shown
        end
      end

      def process_element(node, shown)
        check_relative!(node)
        saved = @rendered.length
        if shown
          @out << "<"
          write_qname(node)
        end
        if exclusive?
          write_exclusive_namespaces(node, shown)
        else
          write_inclusive_namespaces(node, shown)
        end
        write_attributes(node, shown)
        @out << ">" if shown
        node.pure.children.each { |child| process_node(child) }
        if shown
          @out << "</"
          write_qname(node)
          @out << ">"
        end
        @rendered = @rendered[0...saved]
      end

      def write_qname(node)
        prefix = node.namespace&.prefix
        @out << "#{prefix}:" if prefix && !prefix.empty?
        @out << node.name
      end

      def check_relative!(node)
        node.pure.namespace_definitions.each do |ns|
          href = ns.href.to_s
          next if href.empty?

          scheme = href[/\A([A-Za-z][A-Za-z0-9+.-]*):/, 1]
          raise RuntimeError, "canonicalization failed" if scheme.nil? || scheme.empty?
        end
      end

      def write_inclusive_namespaces(node, shown)
        chosen = []
        inscope_namespaces(node).each do |ns|
          next if xml_namespace?(ns)
          next unless visible?(ns, node)

          chosen << ns unless rendered_same?(ns)
          record(ns) if shown
        end
        emit_namespaces(chosen)
      end

      def write_exclusive_namespaces(node, shown)
        chosen = []
        Array(@inclusive).each do |prefix|
          prefix = nil if prefix.empty? || prefix == "#default"
          ns = active_ns(node, prefix)
          next unless ns && !xml_namespace?(ns)
          next unless visible?(ns, node)

          chosen << ns unless rendered_same?(ns)
          record(ns) if shown
        end

        ns = node.namespace || active_ns(node, nil)
        if ns && !xml_namespace?(ns)
          if shown && visible?(ns, node) && !rendered_same?(ns)
            chosen << ns
          end
          record(ns) if shown
        end

        node.pure.attributes.each do |attr|
          attr_ns = attr.namespace
          next unless attr_ns && !xml_namespace?(attr_ns)
          next unless visible?(attr, node)

          chosen << attr_ns if shown && !rendered_same?(attr_ns)
          record(attr_ns)
        end
        emit_namespaces(chosen)
      end

      def emit_namespaces(list)
        seen = {}
        ordered = list.select do |ns|
          key = ns.prefix.to_s
          next false if seen[key]

          seen[key] = true
        end
        ordered.sort_by! { |ns| ns.prefix.to_s }
        ordered.each do |ns|
          if ns.prefix.nil? || ns.prefix.empty?
            @out << %( xmlns="#{escape_attr(ns.href)}")
          else
            @out << %( xmlns:#{ns.prefix}="#{escape_attr(ns.href)}")
          end
        end
      end

      def write_attributes(node, shown)
        attrs = []
        node.pure.attributes.each do |attr|
          attrs << attr if visible?(attr, node)
        end
        if shown && node.parent
          parent = node.parent
          grandparent = parent.respond_to?(:parent) ? parent.parent : nil
          parent_shown = visible?(parent, grandparent)
          inherit_xml_attributes(node, attrs) unless parent_shown || exclusive?
        end
        attrs.sort_by! { |attr| attribute_key(attr) }
        attrs.each { |attr| write_attr(attr) }
      end

      def inherit_xml_attributes(node, attrs)
        present = attrs.select { |attr| xml_attr?(attr) }.map(&:name)
        current = node.parent
        while current&.element?
          current.pure.attributes.each do |attr|
            next unless xml_attr?(attr)
            next unless attr.name == "lang" || attr.name == "space"
            next if present.include?(attr.name)

            attrs << attr
            present << attr.name
          end
          current = current.parent
        end
      end

      def write_attr(attr)
        prefix = attr.namespace&.prefix
        name = prefix && !prefix.empty? ? "#{prefix}:#{attr.name}" : attr.name
        @out << %( #{name}="#{escape_attr(attr.value)}")
      end

      def attribute_key(attr)
        href = attr.namespace&.href
        prefix = attr.namespace&.prefix
        if href.nil? || prefix.nil? || prefix.empty?
          [0, "", attr.name.to_s]
        else
          [1, href.to_s, attr.name.to_s]
        end
      end

      def write_pi(node)
        @out << "<?#{node.name}"
        data = node.content.to_s
        @out << " #{data}" unless data.empty?
        @out << "?>"
      end

      def inscope_namespaces(node)
        found = {}
        current = node
        while current&.element?
          current.pure.namespace_definitions.each do |ns|
            found[ns.prefix] ||= ns
          end
          current = current.parent
        end
        found.values
      end

      def active_ns(node, prefix)
        node.send(:search_ns, node, prefix)
      end

      def xml_namespace?(ns)
        ns.prefix == "xml" && ns.href == XML_HREF
      end

      def xml_attr?(attr)
        attr.namespace && xml_namespace?(attr.namespace)
      end

      def record(ns)
        @rendered << [ns.prefix, ns.href.to_s]
      end

      def rendered_same?(ns)
        match = @rendered.reverse.find { |prefix, _href| prefix == ns.prefix }
        match && match[1] == ns.href.to_s
      end

      def escape_text(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\r", "&#xD;")
      end

      def escape_attr(text)
        escape_text(text).gsub('"', "&quot;").gsub("\t", "&#x9;").gsub("\n", "&#xA;")
      end
    end
  end
end
