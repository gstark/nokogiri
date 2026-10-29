# frozen_string_literal: true

require_relative "entities"

module Nokogiri
  module Pure
    XML_NS_HREF = "http://www.w3.org/XML/1998/namespace"

    module Support
      module_function

      def document_for(node)
        return node if node.is_a?(XML::Document)
        return node.document if node.respond_to?(:document) && node.document

        nil
      end

      def rehome(node, document)
        node.pure.document = document
        node.pure.attributes.each { |attr| rehome(attr, document) }
        node.pure.children.each { |child| rehome(child, document) }
      end

      def node_set_document(node)
        return node if node.is_a?(XML::Document)

        node.document
      end
    end

    class State
      attr_accessor :name, :type, :document, :parent, :namespace, :content,
        :line, :column, :lang, :version, :encoding, :url,
        :external_id, :system_id, :xml_namespace, :external_subset
      attr_reader :children, :attributes, :namespace_definitions

      EMPTY_LIST = [].freeze

      def initialize
        @children = []
        @attributes = []
        @namespace_definitions = []
      end

      def self.attach(owner, **attrs)
        state = new
        attrs.each { |key, value| state.public_send(:"#{key}=", value) }
        owner.instance_variable_set(:@pure, state)
        state
      end

      # Parser hot path. Assign the fields directly. Public constructors keep #attach.
      def self.fast_attach(owner, type, name, document, content = nil, line = nil)
        state = leaf_type?(type) ? leaf_new : new
        state.fast_fill(type, name, document, content, line)
        owner.instance_variable_set(:@pure, state)
        state
      end

      # Text-like nodes never gain children or attributes. One frozen list
      # stands in for the three arrays State#initialize would allocate.
      def self.leaf_type?(type)
        type == XML::Node::TEXT_NODE ||
          type == XML::Node::COMMENT_NODE ||
          type == XML::Node::CDATA_SECTION_NODE ||
          type == XML::Node::PI_NODE
      end

      def self.leaf_new
        state = allocate
        state.instance_variable_set(:@children, EMPTY_LIST)
        state.instance_variable_set(:@attributes, EMPTY_LIST)
        state.instance_variable_set(:@namespace_definitions, EMPTY_LIST)
        state
      end

      def fast_fill(type, name, document, content, line)
        @type = type
        @name = name
        @document = document
        @content = content unless content.nil?
        @line = line unless line.nil?
      end

      def duplicate(level, document)
        # Copies are ordinary states. A flat state must not stay lazy on the copy.
        copy = State.new
        copy.name = name
        copy.type = type
        copy.document = document
        copy.content = content&.dup
        copy.line = line
        copy.column = column
        copy.lang = lang
        copy.version = version
        copy.encoding = encoding
        copy.url = url
        copy.external_id = external_id
        copy.system_id = system_id
        namespace_definitions.each do |ns|
          copy.namespace_definitions << XML::Namespace.new(document, ns.prefix, ns.href)
        end
        if namespace
          copy.namespace = copy.namespace_definitions.find { |ns|
            ns.prefix == namespace.prefix && ns.href == namespace.href
          } || namespace
        end
        attributes.each do |attr|
          attr_copy = attr.dup(level, document)
          attr_copy.pure.parent = nil
          copy.attributes << attr_copy
        end
        if level >= 1
          children.each do |child|
            child_copy = child.dup(1, document)
            child_copy.pure.parent = nil
            copy.children << child_copy
          end
        end
        copy
      end
    end
  end

  module XML
    class Namespace
      def initialize(document, prefix, href)
        @document = document
        @prefix = prefix&.to_s
        @prefix = nil if @prefix&.empty?
        @href = href&.to_s
      end

      attr_reader :prefix, :href
    end

    class Node
      def self.owner_for(document, position, klass_name, error)
        if document.is_a?(Document)
          document
        elsif document.is_a?(Node)
          unless klass_name == "Comment" || klass_name == "EntityReference" || klass_name == "ProcessingInstruction"
            warn(
              "Passing a Node as the #{position} parameter to #{klass_name}.new is deprecated. Please pass a Document instead. This will become an error in Nokogiri v1.17.0.",
              category: :deprecated,
            )
          end
          document.document
        elsif error == :argument
          raise ArgumentError, "document must be a Nokogiri::XML::Node"
        else
          raise TypeError, "wrong argument type #{document.class} (expected Nokogiri::XML::Node)"
        end
      end

      def self.string_content(content)
        unless content.respond_to?(:to_str)
          raise TypeError, "no implicit conversion of #{content.class} into String"
        end

        content.to_str
      end

      def pure
        @pure || raise("node has no pure-Ruby document state")
      end

      def self.new(name, document = nil, *rest, &block)
        unless document.is_a?(Node)
          raise ArgumentError, "document must be a Nokogiri::XML::Node"
        end
        unless document.is_a?(Document)
          warn(
            "Passing a Node as the second parameter to Node.new is deprecated. Please pass a Document instead, or prefer an alternative constructor like Node#add_child. This will become an error in Nokogiri v1.17.0.",
            category: :deprecated,
          )
        end

        owner = document.is_a?(Document) ? document : document.document
        node = (self == Node ? Element : self).allocate
        Pure::State.attach(
          node,
          type: ELEMENT_NODE,
          name: name.to_s,
          document: owner,
        )
        node.send(:initialize, name, document, *rest, &block)
        yield node if block_given?
        node
      end

      def data_ptr?
        !@pure.nil?
      end

      def pointer_id
        pure.object_id
      end

      def node_type
        pure.type
      end

      def node_name
        pure.name.to_s
      end

      def node_name=(value)
        retire_html_cache!
        pure.name = value.to_s
      end

      def document
        pure.document
      end

      def parent
        pure.parent
      end

      def line
        pure.line
      end

      def line=(value)
        pure.line = value
      end

      def lang
        node = self
        while node
          return node.pure.lang if node.pure.lang
          break if node.document? || node.parent.nil?

          node = node.parent
        end
        nil
      end

      def lang=(value)
        pure.lang = value&.to_s
      end

      def content
        case node_type
        when TEXT_NODE, CDATA_SECTION_NODE, COMMENT_NODE, PI_NODE, ATTRIBUTE_NODE
          pure.content.to_s
        else
          collect_text(pure)
        end
      end

      # Element content= escapes, then native_content= decodes. The stored
      # text is the input. xml/node.rb defines content= after this file, so
      # the override that skips both scans lives in pure/element_content.rb.
      def replace_element_text(text)
        retire_flat_tree!
        kids = pure.children
        index = kids.length
        while index > 0
          index -= 1
          child_state = kids[index].instance_variable_get(:@pure)
          child_state.parent = nil if child_state
        end
        kids.clear
        return if text.empty?

        node = XML::Text.allocate
        state = Pure::State.leaf_new
        state.fast_fill(TEXT_NODE, "text", document, text, nil)
        state.parent = self
        node.instance_variable_set(:@pure, state)
        kids << node
        node.decorate!
        node
      end
      private :replace_element_text

      def native_content=(string)
        retire_html_cache!
        value = string.nil? ? nil : string.to_s
        if text? || cdata? || comment? || processing_instruction? || node_type == ATTRIBUTE_NODE
          pure.content = value
        elsif element?
          decoded = value.empty? ? value : Pure::Entities.decode_predefined(value)
          replace_element_text(decoded)
        else
          pure.children.dup.each(&:unlink)
          decoded = Pure::Entities.decode_predefined(value.to_s)
          add_child_node(Text.new(decoded, document)) unless decoded.empty?
        end
        string
      end

      def blank?
        return false unless text? || cdata?

        content.match?(/\A\s*\z/)
      end

      def children
        NodeSet.new(Pure::Support.node_set_document(self), pure.children.dup)
      end

      def child
        pure.children.first
      end

      def element_children
        NodeSet.new(Pure::Support.node_set_document(self), pure.children.select(&:element?))
      end

      def first_element_child
        pure.children.find(&:element?)
      end

      def last_element_child
        pure.children.reverse_each.find(&:element?)
      end

      def next_sibling
        siblings = sibling_list
        return unless siblings

        siblings[siblings.index(self).to_i + 1]
      end

      def previous_sibling
        siblings = sibling_list
        return unless siblings

        index = siblings.index(self)
        return if index.nil? || index.zero?

        siblings[index - 1]
      end

      def next_element
        sibling = self
        loop do
          sibling = sibling.next_sibling
          return if sibling.nil?
          return sibling if sibling.element?
        end
      end

      def previous_element
        sibling = self
        loop do
          sibling = sibling.previous_sibling
          return if sibling.nil?
          return sibling if sibling.element?
        end
      end

      def unlink
        retire_flat_tree!
        parent_node = pure.parent
        if parent_node
          parent_node.pure.children.delete(self)
          parent_node.pure.attributes.delete(self)
          pure.parent = nil
        end
        self
      end

      def add_child_node(node)
        retire_flat_tree!
        if text? || cdata? || comment? || processing_instruction? || node_type == ATTRIBUTE_NODE || node_type == ENTITY_REF_NODE
          raise ArgumentError, "cannot add a child to a #{name} node"
        end
        raise_if_cycle!(self, node)
        node.unlink
        Pure::Support.rehome(node, Pure::Support.node_set_document(self))
        if node.text? && (last = pure.children.last)&.text?
          return absorb_text(last, node)
        end

        node.pure.parent = self
        pure.children << node
        node.decorate! if node.respond_to?(:decorate!)
        adopt_namespaces(node)
        node
      end

      def add_next_sibling_node(node)
        retire_html_cache!
        parent_node = pure.parent
        raise "Cannot add sibling to a node with no parent" unless parent_node

        raise_if_cycle!(parent_node, node)
        siblings = parent_node.pure.children
        node.unlink
        index = siblings.index(self)
        Pure::Support.rehome(node, parent_node.document)
        node.pure.parent = parent_node
        siblings.insert(index + 1, node)
        node.decorate! if node.respond_to?(:decorate!)
        adopt_namespaces(node)
        coalesce_blank_siblings(node)
        node
      end

      def add_previous_sibling_node(node)
        retire_html_cache!
        parent_node = pure.parent
        raise "Cannot add sibling to a node with no parent" unless parent_node

        raise_if_cycle!(parent_node, node)
        siblings = parent_node.pure.children
        node.unlink
        index = siblings.index(self)
        Pure::Support.rehome(node, parent_node.document)
        node.pure.parent = parent_node
        siblings.insert(index, node)
        node.decorate! if node.respond_to?(:decorate!)
        adopt_namespaces(node)
        coalesce_blank_siblings(node)
        node
      end

      def replace_node(node)
        retire_html_cache!
        parent_node = pure.parent
        raise "Cannot replace a node with no parent" unless parent_node

        raise_if_cycle!(parent_node, node)
        siblings = parent_node.pure.children
        index = siblings.index(self)
        node.unlink
        Pure::Support.rehome(node, parent_node.document)
        node.pure.parent = parent_node
        siblings[index] = node
        pure.parent = nil
        node.decorate! if node.respond_to?(:decorate!)
        adopt_namespaces(node)
        merge_adjacent_text(node)
      end

      def compare(other)
        return 0 if equal?(other)

        own_chain = ancestor_chain
        other_chain = other.send(:ancestor_chain)
        return 1 if own_chain.empty? || other_chain.empty? || !own_chain[0].equal?(other_chain[0])

        shared = 0
        limit = [own_chain.length, other_chain.length].min
        shared += 1 while shared < limit && own_chain[shared].equal?(other_chain[shared])
        return -1 if shared == own_chain.length
        return 1 if shared == other_chain.length

        parent_node = own_chain[shared - 1]
        siblings = parent_node.pure.children
        left = siblings.index(own_chain[shared])
        right = siblings.index(other_chain[shared])
        left <=> right
      end

      def attribute_nodes
        NodeSet.new(Pure::Support.node_set_document(self), pure.attributes.dup)
      end

      def attribute(name)
        pure.attributes.find { |attr| attr.name == name.to_s }
      end

      def attribute_with_ns(name, namespace)
        href = namespace&.to_s
        pure.attributes.find { |attr| attr.name == name.to_s && attr.namespace&.href == href }
      end

      def namespace
        pure.namespace
      end

      def namespace_definitions
        pure.namespace_definitions.dup
      end

      def namespace_scopes
        scopes = []
        seen = {}
        node = self
        while node && !node.document? && !node.fragment?
          node.pure.namespace_definitions.each do |ns|
            next if seen.key?(ns.prefix)

            seen[ns.prefix] = true
            scopes << ns
          end
          node = node.parent
        end
        scopes
      end

      def add_namespace_definition(prefix, href)
        retire_html_cache!
        prefix = prefix&.to_str
        prefix = nil if prefix.nil? || prefix.empty?
        if href.nil?
          pure.namespace_definitions.delete_if { |ns| ns.prefix == prefix }
          if prefix.nil? && (namespace.nil? || namespace.prefix.nil?)
            pure.namespace = parent.namespace if parent&.element?
          end
          return
        end
        href = href.to_str
        existing = search_ns(self, prefix)
        if existing
          pure.namespace = existing if prefix.nil? || !element?
          return existing
        end

        target = element? ? self : parent
        return unless target&.element?

        ns = Namespace.new(document, prefix, href)
        target.pure.namespace_definitions << ns
        pure.namespace = ns if prefix.nil? || !target.equal?(self)
        ns
      end

      def key?(name)
        get(name.to_s) != nil
      end

      def namespaced_key?(name, namespace)
        !attribute_with_ns(name, namespace).nil?
      end

      def encode_special_chars(string)
        Pure::Entities.escape_attr(string)
      end

      def in_context(contents, options)
        owner = Pure::Support.node_set_document(self)
        nodes = Pure::Parser.parse_fragment(owner, contents.to_s, self, Integer(options))
        NodeSet.new(owner, nodes)
      end

      def native_write_to(io, encoding, indentation, options)
        Pure::Serializer.write(self, io, encoding, indentation.to_s, Integer(options))
        io
      end

      def path
        return "/" if document?
        return "?" if fragment?
        return "/#{path_step}" if parent.nil? || parent.document? || parent.fragment?

        "#{parent.path}/#{path_step}"
      end

      def internal_subset
        owner = document? ? self : document
        return unless owner

        owner.pure.children.find { |node| node.is_a?(DTD) }
      end

      def external_subset
        owner = document? ? self : document
        owner&.pure&.external_subset
      end

      def create_internal_subset(name, external_id, system_id)
        raise "Document already has an internal subset" if internal_subset

        dtd = build_dtd(name, external_id, system_id)
        add_child_node(dtd)
        dtd
      end

      def create_external_subset(name, external_id, system_id)
        retire_html_cache!
        owner = document? ? self : document
        raise "Document already has an external subset" if owner.pure.external_subset

        dtd = build_dtd(name, external_id, system_id)
        owner.pure.external_subset = dtd
        dtd
      end

      def remove_namespaces!
        retire_html_cache!
        owner = document? ? self : document
        flat = owner&.instance_variable_get(:@flat)
        if flat
          if document?
            flat.strip!
            return self
          end
          flat.retire!
        end
        strip_namespaces(self)
        self
      end

      def retire_flat_tree!
        owner = document? ? self : document
        owner&.instance_variable_get(:@flat)&.retire!
        retire_html_cache!(owner)
      end

      def retire_html_cache!(owner = nil)
        owner ||= document? ? self : document
        return unless owner&.instance_variable_defined?(:@html_pieces)

        owner.remove_instance_variable(:@html_pieces)
      end
      private :retire_html_cache!

      def create_entity(name, type = nil, external_id = nil, system_id = nil, content = nil)
        node = XML::EntityDecl.allocate
        Pure::State.attach(
          node,
          type: ENTITY_DECL,
          name: name.to_s,
          document: document? ? self : self.document,
          content: content&.to_s,
          external_id: external_id&.to_s,
          system_id: system_id&.to_s,
        )
        node.instance_variable_set(:@entity_type, type || XML::EntityDecl::INTERNAL_GENERAL)
        node
      end

      def dump_html
        to_html
      end

      def prepend_newline?
        false
      end

      def html_standard_serialize(*)
        to_html
      end

      def process_xincludes(_options)
        self
      end

      def safe_process_xinclude(_options)
        self
      end

      protected

      def initialize_copy_with_args(other, level, new_parent_doc = nil)
        unless other.is_a?(Node)
          raise TypeError, "argument must be a kind of Nokogiri::XML::Node"
        end

        document = new_parent_doc || other.document
        @pure = other.pure.duplicate(Integer(level), document)
        @pure.parent = nil
        pure.children.each { |child| child.pure.parent = self }
        pure.attributes.each { |attr| attr.pure.parent = self }
        decorate_copy(self)
        self
      end

      private

      def get(name)
        if (colon = name.index(":"))
          prefix = name[0...colon]
          local = name[(colon + 1)..]
          href = prefix == "xml" ? Pure::XML_NS_HREF : namespace_scopes.find { |ns| ns.prefix == prefix }&.href
          attr = if href
            pure.attributes.find { |item| item.name == local && item.namespace&.href == href }
          else
            pure.attributes.find { |item| item.name == name && item.namespace.nil? }
          end
        else
          attr = pure.attributes.find { |item| item.name == name && item.namespace.nil? }
        end
        attr&.value
      end

      def set(name, value)
        local = name
        namespace = nil
        if (colon = name.index(":"))
          prefix = name[0...colon]
          local = name[(colon + 1)..]
          namespace = if prefix == "xml"
            Pure::Support.node_set_document(self).xml_namespace
          else
            namespace_scopes.find { |item| item.prefix == prefix }
          end
          if namespace.nil?
            local = name
          end
        end
        attr = pure.attributes.find do |item|
          item.name == local && item.namespace&.href == namespace&.href && (namespace ? true : item.namespace.nil?)
        end
        unless attr
          owner = Pure::Support.node_set_document(self)
          attr = Attr.new(owner, local)
          attr.pure.namespace = namespace if namespace
          attr.pure.parent = self
          pure.attributes << attr
        end
        attr.value = value
        value
      end

      def set_namespace(ns)
        retire_html_cache!
        pure.namespace = ns
        ns
      end

      def sibling_list
        return if pure.parent.nil?
        return if node_type == ATTRIBUTE_NODE

        pure.parent.pure.children
      end

      def ancestor_chain
        chain = []
        node = self
        while node
          chain.unshift(node)
          break if node.document? || node.fragment? || !node.respond_to?(:parent)

          node = node.parent
        end
        chain
      end

      def absorb_text(survivor, absorbed)
        return survivor if survivor.pure.equal?(absorbed.pure)

        survivor.pure.content = survivor.pure.content.to_s + absorbed.pure.content.to_s
        parent_node = absorbed.pure.parent
        parent_node.pure.children.delete(absorbed) if parent_node
        absorbed.instance_variable_set(:@pure, survivor.pure)
        survivor
      end

      def coalesce_blank_siblings(node)
        return node unless node.text? && node.blank?

        previous = node.previous_sibling
        if previous&.text? && previous.blank?
          return absorb_text(previous, node)
        end

        nxt = node.next_sibling
        if nxt&.text? && nxt.blank?
          return absorb_text(node, nxt)
        end

        node
      end

      def raise_if_cycle!(parent_node, node)
        ancestor = parent_node
        while ancestor
          if ancestor.equal?(node)
            raise "cycle detected: node '#{node.name}' is an ancestor of itself"
          end
          break if ancestor.document? || ancestor.fragment? || !ancestor.respond_to?(:parent)

          ancestor = ancestor.parent
        end
      end

      def adopt_namespaces(node)
        ensure_declared_namespaces(node)
        relink_namespace(node)
      end

      def ensure_declared_namespaces(node)
        ensure_declared_namespaces_from(node, node)
      end

      def ensure_declared_namespaces_from(node, tree)
        return unless node.element?

        declare_namespace_on(node, tree)
        node.pure.attributes.each { |attr| declare_namespace_on(attr, tree) }
        node.pure.children.each do |child|
          ensure_declared_namespaces_from(child, tree) if child.element?
        end
      end

      def declare_namespace_on(node, tree)
        ns = node.namespace
        return unless ns

        if ns.prefix == "xml"
          owner = node.document
          node.pure.namespace = owner.xml_namespace if owner.respond_to?(:xml_namespace)
          return
        end

        found = search_ns(node, ns.prefix)
        if found && found.href == ns.href
          node.pure.namespace = found
          return
        end

        parent_node = node.parent
        return if parent_node.nil? || parent_node.fragment?

        holder = tree.element? ? tree : tree.parent
        return unless holder&.element?

        clash = holder.pure.namespace_definitions.find { |item| item.prefix == ns.prefix }
        if clash
          node.pure.namespace = clash if clash.href == ns.href
          return
        end

        created = Namespace.new(holder.document, ns.prefix, ns.href)
        holder.pure.namespace_definitions << created
        node.pure.namespace = created
      end

      def relink_namespace(node)
        return unless node.element? || node.node_type == ATTRIBUTE_NODE

        if node.node_type == ATTRIBUTE_NODE
          adopt_attribute_name(node)
          return
        end

        adopt_inscope_namespace(node)
        if node.parent
          if node.namespace.nil? && !node.parent.document? && inherit_namespaces?(node)
            node.pure.namespace = node.parent.namespace
          end
          drop_redundant_namespace_definitions(node)
          retarget_namespace(node)
        end
        node.pure.children.each { |child| relink_namespace(child) }
        node.pure.attributes.each { |attr| relink_namespace(attr) }
      end

      def adopt_attribute_name(node)
        return unless node.namespace.nil? || node.namespace.prefix.nil?
        return unless node.name.include?(":")

        prefix, local = node.name.split(":", 2)
        return if prefix.nil? || prefix.empty? || prefix == "xmlns"

        found = search_ns(node, prefix)
        return unless found

        node.pure.name = local
        node.pure.namespace = found
      end

      def adopt_inscope_namespace(node)
        return unless node.namespace.nil? || node.namespace.prefix.nil?

        prefix = nil
        local = nil
        if node.name.include?(":")
          prefix, local = node.name.split(":", 2)
          return if prefix.nil? || prefix.empty?
        end
        found = search_ns(node, prefix)
        return unless found

        node.pure.name = local if local && !local.empty?
        node.pure.namespace = found
      end

      def inherit_namespaces?(node)
        owner = node.document
        owner.respond_to?(:namespace_inheritance) && owner.namespace_inheritance
      end

      def drop_redundant_namespace_definitions(node)
        node.pure.namespace_definitions.delete_if do |current|
          found = search_ns(node.parent, current.prefix)
          found && found.href == current.href
        end
      end

      def retarget_namespace(node)
        ns = node.namespace
        return unless ns

        found = search_ns(node, ns.prefix)
        return unless found && !found.equal?(ns)
        return unless found.prefix == ns.prefix && found.href == ns.href

        node.pure.namespace = found
      end

      def search_ns(node, prefix)
        return if node.nil?

        prefix = nil if prefix.respond_to?(:empty?) && prefix.empty?
        if prefix == "xml"
          owner = node.document? ? node : node.document
          return owner&.xml_namespace
        end

        current = node
        while current
          if current.element?
            current.pure.namespace_definitions.each do |ns|
              next if ns.href.nil?
              return ns if prefix.nil? ? ns.prefix.nil? : ns.prefix == prefix
            end
            unless current.equal?(node)
              ns = current.namespace
              if ns && ns.href && (prefix.nil? ? ns.prefix.nil? : ns.prefix == prefix)
                return ns
              end
            end
          end
          break if current.document? || current.fragment? || !current.respond_to?(:parent)

          current = current.parent
        end
        nil
      end

      def search_ns_by_href(node, href)
        return if node.nil? || href.nil?

        current = node
        while current
          if current.element?
            current.pure.namespace_definitions.each do |ns|
              next unless ns.href == href

              visible = search_ns(current, ns.prefix)
              return ns if visible.equal?(ns)
            end
            unless current.equal?(node)
              ns = current.namespace
              if ns && ns.href == href
                visible = search_ns(current, ns.prefix)
                return ns if visible.equal?(ns)
              end
            end
          end
          break if current.document? || current.fragment? || !current.respond_to?(:parent)

          current = current.parent
        end
        nil
      end

      def decorate_copy(node)
        node.decorate! if node.respond_to?(:decorate!)
        node.pure.children.each { |child| decorate_copy(child) }
        node.pure.attributes.each { |attr| decorate_copy(attr) }
      end

      def merge_adjacent_text(node)
        return node unless node.text?

        if (previous = node.previous_sibling)&.text?
          previous.pure.content = previous.pure.content.to_s + node.pure.content.to_s
          node.unlink
          node = previous
        end
        if (following = node.next_sibling)&.text?
          node.pure.content = node.pure.content.to_s + following.pure.content.to_s
          following.unlink
        end
        node
      end

      def collect_text(state)
        buffer = +""
        state.children.each do |child|
          case child.node_type
          when TEXT_NODE, CDATA_SECTION_NODE
            buffer << child.pure.content.to_s
          when ELEMENT_NODE
            buffer << collect_text(child.pure)
          end
        end
        buffer
      end

      def path_step
        if text?
          return indexed_kind("text()") { |child| child.text? }
        end
        if comment?
          return indexed_kind("comment()") { |child| child.comment? }
        end

        step = if namespace&.prefix && !namespace.prefix.empty?
          "#{namespace.prefix}:#{name}"
        else
          name
        end
        return step unless parent

        same = parent.pure.children.select { |child|
          child.element? && child.name == name && child.namespace&.href == namespace&.href
        }
        return step if same.length < 2

        position = same.index(self)
        "#{step}[#{position + 1}]"
      end

      def indexed_kind(label)
        return label unless parent

        same = parent.pure.children.select { |child| yield child }
        return label if same.length < 2

        "#{label}[#{same.index(self) + 1}]"
      end

      def build_dtd(name, external_id, system_id)
        dtd = DTD.allocate
        Pure::State.attach(
          dtd,
          type: DTD_NODE,
          name: name.to_s,
          document: document? ? self : document,
          external_id: external_id&.to_s,
          system_id: system_id&.to_s,
        )
        dtd
      end

      def strip_namespaces(node)
        node.pure.namespace = nil
        defs = node.pure.namespace_definitions
        defs.clear unless defs.empty?
        node.pure.attributes.each { |attr| attr.pure.namespace = nil }
        node.pure.children.each { |child| strip_namespaces(child) }
      end
    end

    class Document < Node
      def self.new(*args, &block)
        version = args[0]
        version = version.respond_to?(:to_str) ? version.to_str : "1.0"
        document = allocate
        type = if defined?(Nokogiri::HTML4::Document) && self <= Nokogiri::HTML4::Document && self != Document
          HTML_DOCUMENT_NODE
        else
          DOCUMENT_NODE
        end
        Pure::State.attach(
          document,
          type: type,
          name: "document",
          version: version,
        )
        document.pure.document = document
        document.send(:initialize, *args, &block)
        document
      end

      def self.read_memory(string, url, encoding, options)
        options = Integer(options)
        document = new
        if url
          document.pure.url = url.to_s.encode(Encoding::UTF_8)
        end
        source, detected = Pure::Text.transcode_input(string.to_s, encoding)
        document.encoding = (encoding || detected)&.to_s
        document.encoding = document.encoding.encode(Encoding::UTF_8) if document.encoding
        Pure::Parser.parse(document, source, options)
        recover = options & ParseOptions::RECOVER != 0
        if !recover && document.errors.any? { |err| err.fatal? || err.level.nil? }
          if document.html?
            raise SyntaxError, "Parser without recover option encountered error or warning"
          end

          exception = SyntaxError.aggregate(document.errors)
          raise exception if exception
        end
        document
      end

      def self.read_io(io, url, encoding, options)
        read_memory(read_source(io), url, encoding, options)
      end

      def self.read_source(io)
        return io.read.to_s unless io.method(:read).arity == 1

        chunks = +""
        while (chunk = io.read(16_384))
          chunks << chunk
        end
        chunks
      end

      def root
        node = pure.children.find(&:element?)
        decorate(node) if node
        node
      end

      def root=(node)
        unless node.nil?
          unless node.is_a?(XML::Node)
            raise ArgumentError, "expected Nokogiri::XML::Node but received #{node.class}"
          end
          unless node.element?
            raise TypeError, "root must be a Nokogiri::XML::Element"
          end
          node = node.dup(1, self) if node.document != self
        end
        current = pure.children.find(&:element?)
        current&.unlink
        add_child_node(node) if node
        node
      end

      def encoding
        pure.encoding
      end

      def encoding=(value)
        retire_html_cache!
        if value.nil?
          pure.encoding = nil
          return
        end
        unless value.respond_to?(:to_str)
          raise TypeError, "no implicit conversion of #{value.class} into String"
        end

        pure.encoding = value.to_str
      end

      def version
        pure.version || "1.0"
      end

      def url
        pure.url
      end

      def canonicalize(mode = nil, inclusive_namespaces = nil, with_comments = false, &block)
        Pure::C14n.canonicalize(self, mode, inclusive_namespaces, with_comments, &block)
      end

      def xml_namespace
        pure.xml_namespace ||= Namespace.new(self, "xml", Pure::XML_NS_HREF)
      end

      protected

      def initialize_copy_with_args(other, level)
        super(other, level, self)
        # Object#dup copies @flat. The copy owns the duplicated nodes, not the table.
        remove_instance_variable(:@flat) if instance_variable_defined?(:@flat)
        remove_instance_variable(:@html_pieces) if instance_variable_defined?(:@html_pieces)
        pure.document = self
        pure.version = other.version
        pure.encoding = other.encoding
        pure.url = other.url
        retarget(self)
        self
      end

      private

      def retarget(document)
        pure.document = document
        pure.attributes.each { |attr| attr.send(:retarget_node, document) }
        pure.children.each { |child| child.send(:retarget_node, document) }
      end
    end

    class Node
      private

      def retarget_node(document)
        pure.document = document
        pure.attributes.each { |attr| attr.send(:retarget_node, document) }
        pure.children.each { |child| child.send(:retarget_node, document) }
      end
    end

    class DocumentFragment < Node
      def self.native_new(document)
        fragment = allocate
        doc = document.is_a?(Document) ? document : document&.document
        Pure::State.attach(
          fragment,
          type: DOCUMENT_FRAG_NODE,
          name: "#document-fragment",
          document: doc,
        )
        fragment
      end
    end

    class Text < CharacterData
      def self.new(content, document = nil, *rest, &block)
        owner = Node.owner_for(document, "second", "Text", :type)
        node = allocate
        Pure::State.attach(
          node,
          type: TEXT_NODE,
          name: "text",
          document: owner,
          content: content.to_s,
        )
        node.send(:initialize, content, document, *rest, &block)
        yield node if block_given?
        node
      end
    end

    class Comment < CharacterData
      def self.new(document, content = "", *rest, &block)
        owner = Node.owner_for(document, "first", "Comment", :argument)
        node = allocate
        Pure::State.attach(
          node,
          type: COMMENT_NODE,
          name: "comment",
          document: owner,
          content: content.to_s,
        )
        node.send(:initialize, document, content, *rest, &block)
        yield node if block_given?
        node
      end
    end

    class CDATA < Text
      def self.new(document, content = "", *rest, &block)
        owner = Node.owner_for(document, "first", "CDATA", :type)
        text = Node.string_content(content)
        node = allocate
        Pure::State.attach(
          node,
          type: CDATA_SECTION_NODE,
          name: "#cdata-section",
          document: owner,
          content: text,
        )
        node.send(:initialize, document, content, *rest, &block)
        yield node if block_given?
        node
      end
    end

    class ProcessingInstruction < Node
      def self.new(document, name, content = "", *rest, &block)
        owner = Node.owner_for(document, "first", "ProcessingInstruction", :argument)
        node = allocate
        Pure::State.attach(
          node,
          type: PI_NODE,
          name: name.to_s,
          document: owner,
          content: content.to_s,
        )
        node.send(:initialize, document, name, content, *rest, &block)
        yield node if block_given?
        node
      end
    end

    class Attr < Node
      def self.new(document, name, *rest, &block)
        unless document.is_a?(Document)
          raise ArgumentError, "document must be a Nokogiri::XML::Document"
        end

        node = allocate
        Pure::State.attach(
          node,
          type: ATTRIBUTE_NODE,
          name: name.to_s,
          document: document,
        )
        node.send(:initialize, document, name, *rest, &block)
        yield node if block_given?
        node
      end

      def value=(content)
        retire_html_cache!
        pure.content = content.nil? ? nil : content.to_s
        content
      end
    end

    class EntityReference < Node
      def self.new(document, name, *rest, &block)
        owner = Node.owner_for(document, "first", "EntityReference", :argument)
        node = allocate
        Pure::State.attach(
          node,
          type: ENTITY_REF_NODE,
          name: name.to_s,
          document: owner,
        )
        node.send(:initialize, document, name, *rest, &block)
        yield node if block_given?
        node
      end
    end

    class DTD < Node
      def validate(document)
        document.errors
      end

      def external_id
        pure.external_id
      end

      def system_id
        pure.system_id
      end

      def entities
        declarations(ENTITY_DECL)
      end

      def elements
        declarations(ELEMENT_DECL)
      end

      def attributes
        declarations(ATTRIBUTE_DECL)
      end

      def notations
        @notations || {}
      end

      private

      def declarations(kind)
        pure.children.select { |node| node.node_type == kind }.each_with_object({}) do |node, hash|
          hash[node.name] ||= node
        end
      end
    end

    class NodeSet
      def initialize_copy(other)
        @document = other.document
        @members = other.to_a.dup
        @document.decorate(self) if @document
        self
      end

      def push(node)
        member!(node)
        doc = node.document if node.respond_to?(:document)
        doc.decorate(node) if doc.respond_to?(:decorate)
        members << node
        self
      end

      def length
        members.length
      end

      def [](*args)
        wrap_subset(members.[](*args))
      end

      def slice(*args)
        self[*args]
      end

      def to_a
        members.dup
      end

      def delete(node)
        member!(node)
        members.delete(node) ? node : nil
      end

      def include?(node)
        members.include?(node)
      end

      def unlink
        to_a.each { |node| node.unlink if node.respond_to?(:unlink) }
        self
      end

      def &(other)
        node_set!(other)
        NodeSet.new(document, to_a & other.to_a)
      end

      def -(other)
        node_set!(other)
        NodeSet.new(document, to_a - other.to_a)
      end

      def |(other)
        node_set!(other)
        merged = to_a
        other.each { |node| merged << node unless merged.include?(node) }
        NodeSet.new(document, merged)
      end

      private

      def members
        @members ||= []
      end

      def wrap_subset(value)
        return value unless value.is_a?(Array)

        NodeSet.new(document, value)
      end

      def node_set!(other)
        return if other.is_a?(XML::NodeSet)

        raise ArgumentError, "node_set must be a Nokogiri::XML::NodeSet"
      end

      def member!(node)
        return if node.is_a?(XML::Node) || node.is_a?(XML::Namespace)

        raise ArgumentError, "node must be a Nokogiri::XML::Node or Nokogiri::XML::Namespace"
      end
    end
  end
end
