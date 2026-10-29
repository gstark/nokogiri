# frozen_string_literal: true

module Nokogiri
  module Pure
    # Element and text records for one XML document.
    #
    # The parser writes indexes here and does not allocate a Ruby node per
    # tag. A node is built when a query or a reader asks for that index.
    # Documents that contain comments, doctypes, or processing instructions
    # never use this table.
    class FlatTree
      # These match XML::Node::ELEMENT_NODE and TEXT_NODE. The node
      # constants are defined after this file is loaded.
      ELEMENT = 1
      TEXT = 3

      attr_reader :document

      def initialize(document, source)
        @document = document
        @source = source
        @type = []
        @parent = []
        @nex = []
        @child = []
        @off = []
        @len = []
        @local = []
        @ns = []
        @line = []
        @text_off = []
        @text_len = []
        @text_str = []
        @prefixes = []
        @hrefs = []
        @ns_obj = []
        @attrs = []
        @defs = []
        @lang = []
        @cache = []
        @tail = []
        @top_head = -1
        @top_tail = -1
        @attached = false
        @retired = false
      end

      def add_element(parent, name_off, name_len, local_delta, ns_id, line, defs)
        index = @type.length
        @type << ELEMENT
        @parent << parent
        @nex << -1
        @child << -1
        @off << name_off
        @len << name_len
        @local << local_delta
        @ns << (ns_id.nil? ? -1 : ns_id)
        @line << line
        @text_off << -1
        @text_len << -1
        @text_str << nil
        @attrs << nil
        @defs << (defs.empty? ? nil : defs.dup)
        @lang << nil
        @tail << -1
        link(parent, index)
        index
      end

      def add_text_range(parent, off, len, line)
        add_text_node(parent, line, off, len, nil)
      end

      def add_text(parent, string, line)
        add_text_node(parent, line, -1, -1, string)
      end

      def add_attr(index, local_name, ns_id, value)
        list = (@attrs[index] ||= [])
        list << [local_name, ns_id.nil? ? -1 : ns_id, value]
      end

      def define_ns(prefix, href)
        id = @prefixes.length
        @prefixes << prefix
        @hrefs << href
        id
      end

      def prefix_of(id)
        @prefixes[id]
      end

      def xml_ns_id(document)
        return @xml_ns_id if defined?(@xml_ns_id) && @xml_ns_id

        @xml_ns_id = define_ns("xml", XML_NS_HREF)
        @ns_obj[@xml_ns_id] = document.xml_namespace
        @xml_ns_id
      end

      def set_lang(index, value)
        @lang[index] = value
      end

      def local_name(index)
        delta = @local[index]
        @source.byteslice(@off[index] + delta, @len[index] - delta)
      end

      def raw_eq?(index, off, len)
        return false unless @len[index] == len

        start = @off[index]
        cursor = 0
        while cursor < len
          return false if @source.getbyte(start + cursor) != @source.getbyte(off + cursor)

          cursor += 1
        end
        true
      end

      def declares?(index)
        !@defs[index].nil?
      end

      def named(local, href, limit)
        want = local.bytesize
        out = []
        i = 0
        last = @type.length
        while i < last
          if @type[i] == ELEMENT && local_eq?(i, local, want) && href_is?(@ns[i], href)
            out << wrapper(i)
            return out if limit && out.length >= limit
          end
          i += 1
        end
        out
      end

      # `//parent/child` after namespaces have been removed. Both names
      # must be in no namespace.
      def named_children(parent_name, child_name, limit)
        parent_len = parent_name.bytesize
        child_len = child_name.bytesize
        out = []
        i = 0
        last = @type.length
        while i < last
          if @type[i] == ELEMENT && @ns[i] < 0 && local_eq?(i, parent_name, parent_len)
            child = @child[i]
            while child >= 0
              if @type[child] == ELEMENT && @ns[child] < 0 && local_eq?(child, child_name, child_len)
                out << wrapper(child)
                return out if limit && out.length >= limit
              end
              child = @nex[child]
            end
          end
          i += 1
        end
        out
      end

      def strip!
        i = 0
        last = @type.length
        while i < last
          @ns[i] = -1 if @type[i] == ELEMENT
          i += 1
        end
        @attrs.each do |list|
          next unless list

          list.each { |row| row[1] = -1 }
        end
        @defs.fill(nil)
        @cache.each do |node|
          next unless node&.element?

          state = node.pure
          state.namespace = nil
          defs = state.instance_variable_get(:@namespace_definitions)
          defs.clear if defs && !defs.frozen? && !defs.empty?
          attrs = state.instance_variable_get(:@attributes)
          next unless attrs

          attrs.each do |attr|
            attr.pure.namespace = nil if attr
          end
        end
      end

      def attach_top
        return if @attached

        @attached = true
        index = @top_head
        children = @document.pure.children
        while index >= 0
          node = wrapper(index)
          node.pure.parent = @document
          children << node
          index = @nex[index]
        end
      end

      def retire!
        return if @retired

        @retired = true
        attach_top
        i = 0
        last = @type.length
        while i < last
          node = wrapper(i)
          state = node.pure
          state.children if state.is_a?(FlatState)
          state.attributes if state.is_a?(FlatState)
          state.namespace_definitions if state.is_a?(FlatState)
          i += 1
        end
        @document.remove_instance_variable(:@flat) if @document.instance_variable_defined?(:@flat)
      end

      def fill_children(state)
        index = state.instance_variable_get(:@flat_index)
        kids = []
        child = @child[index]
        owner = @cache[index]
        while child >= 0
          node = wrapper(child)
          node.pure.parent = owner
          kids << node
          child = @nex[child]
        end
        state.instance_variable_set(:@children, kids)
      end

      def fill_attrs(state)
        index = state.instance_variable_get(:@flat_index)
        attrs = []
        defs = []
        list = @defs[index]
        if list
          list.each { |id| defs << ns_object(id) }
        end
        stored = @attrs[index]
        if stored
          owner = @cache[index]
          stored.each do |attr_name, ns_id, value|
            attr = XML::Attr.allocate
            attr_state = State.leaf_new
            attr_state.fast_fill(XML::Node::ATTRIBUTE_NODE, attr_name.dup, @document, value.dup, nil)
            attr_state.parent = owner
            attr_state.namespace = ns_object(ns_id) if ns_id >= 0
            attr.instance_variable_set(:@pure, attr_state)
            attrs << attr
          end
        end
        state.instance_variable_set(:@attributes, attrs)
        state.instance_variable_set(:@namespace_definitions, defs)
      end

      def wrapper(index)
        cached = @cache[index]
        return cached if cached

        if @type[index] == TEXT
          node = text_node(index)
          @cache[index] = node
          return node
        end

        node = XML::Element.allocate
        state = FlatState.allocate
        state.instance_variable_set(:@flat_index, index)
        state.instance_variable_set(:@flat_tree, self)
        state.instance_variable_set(:@flat_kids, false)
        state.instance_variable_set(:@flat_attrs, false)
        state.fast_fill(ELEMENT, local_name(index), @document, nil, @line[index])
        ns_id = @ns[index]
        state.namespace = ns_object(ns_id) if ns_id >= 0
        state.lang = @lang[index] if @lang[index]
        node.instance_variable_set(:@pure, state)
        @cache[index] = node
        parent = @parent[index]
        state.parent = parent < 0 ? @document : wrapper(parent)
        node
      end

      private

      def add_text_node(parent, line, off, len, string)
        index = @type.length
        @type << TEXT
        @parent << parent
        @nex << -1
        @child << -1
        @off << -1
        @len << 0
        @local << 0
        @ns << -1
        @line << line
        @text_off << off
        @text_len << len
        @text_str << string
        @attrs << nil
        @defs << nil
        @lang << nil
        @tail << -1
        link(parent, index)
        index
      end

      def link(parent, index)
        if parent < 0
          if @top_tail < 0
            @top_head = index
          else
            @nex[@top_tail] = index
          end
          @top_tail = index
          return
        end

        if @child[parent] < 0
          @child[parent] = index
        else
          @nex[@tail[parent]] = index
        end
        @tail[parent] = index
      end

      def local_eq?(index, text, want)
        delta = @local[index]
        return false unless @len[index] - delta == want

        @source.byteslice(@off[index] + delta, want) == text
      end

      def prefix_length(index)
        delta = @local[index]
        return if delta.zero?

        delta - 1
      end

      def href_is?(ns_id, href)
        if href.nil?
          ns_id < 0
        else
          ns_id >= 0 && @hrefs[ns_id] == href
        end
      end

      def ns_object(id)
        return nil if id < 0

        @ns_obj[id] ||= XML::Namespace.new(@document, @prefixes[id], @hrefs[id])
      end

      def text_node(index)
        content = @text_str[index]
        if content.nil?
          content = @source.byteslice(@text_off[index], @text_len[index])
          content = Entities.decode_predefined(content) if content.byteindex("&")
          @text_str[index] = content
        end
        node = XML::Text.allocate
        state = State.leaf_new
        state.fast_fill(TEXT, "text", @document, content, @line[index])
        parent = @parent[index]
        state.parent = parent < 0 ? @document : wrapper(parent)
        node.instance_variable_set(:@pure, state)
        node
      end
    end

    # A parsed element whose children and attributes stay on the flat table
    # until something reads them.
    class FlatState < State
      def children
        unless @flat_kids
          @flat_kids = true
          @children = []
          @flat_tree.fill_children(self) if @flat_tree
        end
        @children || EMPTY_LIST
      end

      def attributes
        load_flat_attrs
        @attributes || EMPTY_LIST
      end

      def namespace_definitions
        load_flat_attrs
        @namespace_definitions || EMPTY_LIST
      end

      def load_flat_attrs
        return if @flat_attrs

        @flat_attrs = true
        @attributes = []
        @namespace_definitions = []
        @flat_tree&.fill_attrs(self)
      end
    end
  end
end
