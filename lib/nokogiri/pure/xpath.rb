# frozen_string_literal: true

module Nokogiri
  module Pure
    # XPath 1.0 subset used by the pure backend.
    #
    # Covers location paths, the axes CSS and the document tests need, and the
    # functions the CSS compiler emits.
    class XPath
      NODE_TESTS = %w[text node comment processing-instruction].freeze

      def self.node_limit(limit)
        previous = Thread.current[:nokogiri_pure_node_limit]
        Thread.current[:nokogiri_pure_node_limit] = limit
        yield
      ensure
        Thread.current[:nokogiri_pure_node_limit] = previous
      end

      def self.evaluate(context_node, path, namespaces, variables = nil, handler = nil)
        limit = Thread.current[:nokogiri_pure_node_limit]
        Thread.current[:nokogiri_pure_node_limit] = nil if limit
        if handler.nil? && (variables.nil? || variables.empty?)
          nodes = fast_nodes(context_node, path.to_s, namespaces || {}, limit)
          return XML::NodeSet.new(context_node.document, nodes) unless nodes.nil?
        end

        value = Engine.new(path.to_s, namespaces || {}, variables || {}, handler, node_limit: limit).evaluate(context_node)
        document = context_node.document
        case value.type
        when :nodeset
          XML::NodeSet.new(document, value.nodes)
        when :bool
          value.flag
        when :number
          value.number
        else
          value.text
        end
      ensure
        Thread.current[:nokogiri_pure_node_limit] = limit if limit
      end

      # Direct walks for the location paths CSS and the common calls emit.
      # Any other expression returns nil and uses the full evaluator.
      FAST_NAME = /[A-Za-z_][\w.-]*/
      FAST_ATTR_CHILD = /\A\/\/(#{FAST_NAME})\[@(#{FAST_NAME})=(?:"([^"]*)"|'([^']*)')\]\/(#{FAST_NAME})\z/
      FAST_CLASS = /\A(\.\/\/|\/\/)(#{FAST_NAME})\[contains\(concat\(' ',normalize-space\(@class\),' '\),' ([^']*)'\)\]\z/
      FAST_CHILD = /\A(\.\/\/|\/\/)(#{FAST_NAME})\/(#{FAST_NAME})\z/
      # Optional prefixes on both steps: //ns:item/ns:name, //ns:item/name, //item/ns:name.
      # xpath_impl rewrites the prefix xmlns: to " :" before evaluate.
      # That space is the default namespace, stored under the empty prefix.
      FAST_QCHILD = /\A(\.\/\/|\/\/)(?:(?:(#{FAST_NAME})|( )):)?(#{FAST_NAME})\/(?:(?:(#{FAST_NAME})|( )):)?(#{FAST_NAME})\z/
      FAST_DESC = /\A(\.\/\/|\/\/)(#{FAST_NAME})\/\/(#{FAST_NAME})\z/
      FAST_UNION = /\A\.\/\/(#{FAST_NAME}) \| self::\1\z/
      FAST_QNAME = /\A\/\/(#{FAST_NAME}):(#{FAST_NAME})\z/
      FAST_ONE = /\A(\.\/\/|\/\/)(#{FAST_NAME})\z/

      def self.fast_nodes(context, path, namespaces, limit)
        return nil unless path.start_with?("//", ".//")

        if (match = FAST_ATTR_CHILD.match(path))
          expected = match[3] || match[4]
          return named_attr_children(fast_origin(context, true), match[1], match[2], expected, match[5], limit)
        end
        if (match = FAST_CLASS.match(path))
          # The pattern eats the leading word-boundary space. The capture
          # keeps the trailing space, so " post " arrives as "post ".
          inner = match[3]
          return nil unless inner.end_with?(" ") && inner.length > 1

          needle = inner.chop
          return nil if needle.empty? || needle.include?(" ")

          return named_class(fast_origin(context, match[1] == "//"), match[2], needle, limit)
        end
        if (match = FAST_CHILD.match(path))
          return named_children(fast_origin(context, match[1] == "//"), match[2], match[3], limit)
        end
        if (match = FAST_QCHILD.match(path))
          parent_href = step_href(match[2], match[3], namespaces)
          child_href = step_href(match[5], match[6], namespaces)
          return nil if parent_href == :missing || child_href == :missing
          # //a/b is FAST_CHILD. Do not handle the unprefixed form here.
          return nil if match[2].nil? && match[3].nil? && match[5].nil? && match[6].nil?

          return qnamed_children(
            fast_origin(context, match[1] == "//"),
            match[4], parent_href, match[7], child_href, limit
          )
        end
        if (match = FAST_DESC.match(path))
          return named_descendant(fast_origin(context, match[1] == "//"), match[2], match[3], limit)
        end
        if (match = FAST_UNION.match(path))
          return union_self(context, match[1], limit)
        end
        if (match = FAST_QNAME.match(path))
          return nil unless namespaces.key?(match[1])

          return named(fast_origin(context, true), match[2], namespaces[match[1]], limit)
        end
        if (match = FAST_ONE.match(path))
          return named(fast_origin(context, match[1] == "//"), match[2], nil, limit)
        end

        nil
      end

      # A space mark is the rewritten xmlns prefix. Its URI is under "".
      # A nil prefix is an unprefixed name, which has no namespace.
      # An unbound prefix returns :missing so the full evaluator reports it.
      def self.step_href(prefix, default_mark, namespaces)
        if default_mark
          return :missing unless namespaces.key?("")

          return namespaces[""]
        end
        return nil if prefix.nil?
        return :missing unless namespaces.key?(prefix)

        namespaces[prefix]
      end

      def self.fast_origin(context, absolute)
        return context unless absolute
        return context if context.is_a?(XML::Document)
        return context.document if context.respond_to?(:document) && context.document

        context
      end

      def self.named(root, local, href, limit)
        if root.is_a?(XML::Document) && (flat = root.instance_variable_get(:@flat))
          return flat.named(local, href, limit)
        end

        out = []
        walk_elements(root) do |node, state|
          next unless state.name == local && href_match?(state, href)

          out << node
          return out if limit && out.length >= limit
        end
        out
      end

      def self.named_class(root, local, needle, limit)
        state = root.instance_variable_get(:@pure)
        return [] unless state

        children = state.children
        return [] if children.empty?

        out = []
        stack = []
        index = children.length
        while index > 0
          index -= 1
          stack << children[index]
        end
        element = XML::Node::ELEMENT_NODE
        while (node = stack.pop)
          child_state = node.instance_variable_get(:@pure)
          next unless child_state

          if child_state.type == element && child_state.name == local && child_state.namespace.nil? && class_match?(child_state, needle)
            out << node
            return out if limit && out.length >= limit
          end
          kids = child_state.children
          cursor = kids.length
          while cursor > 0
            cursor -= 1
            stack << kids[cursor]
          end
        end
        out
      end

      # One preorder walk. `//h2//a` is an `a` under an `h2`. The count is
      # how many open ancestors have the parent name, so a nested pair
      # emits the inner node once and in document order.
      def self.named_descendant(root, parent_name, child_name, limit)
        state = root.instance_variable_get(:@pure)
        return [] unless state

        children = state.children
        return [] if children.empty?

        out = []
        stack = []
        index = children.length
        while index > 0
          index -= 1
          stack << [children[index], 0]
        end
        element = XML::Node::ELEMENT_NODE
        while (item = stack.pop)
          node, under = item
          child_state = node.instance_variable_get(:@pure)
          next unless child_state

          now = under
          if child_state.type == element && child_state.namespace.nil?
            if under > 0 && child_state.name == child_name
              out << node
              return out if limit && out.length >= limit
            end
            now += 1 if child_state.name == parent_name
          end
          kids = child_state.children
          cursor = kids.length
          while cursor > 0
            cursor -= 1
            stack << [kids[cursor], now]
          end
        end
        out
      end

      # //prefix:parent/prefix:child. href nil means the step has no namespace.
      # Emit the child when its parent matches, so nested pairs stay in document order.
      def self.qnamed_children(root, parent_name, parent_href, child_name, child_href, limit)
        if root.is_a?(XML::Document) && (flat = root.instance_variable_get(:@flat))
          return flat.named_children_in(parent_name, parent_href, child_name, child_href, limit)
        end

        out = []
        element = XML::Node::ELEMENT_NODE
        each_element(root) do |node, state|
          next unless state.name == child_name && href_match?(state, child_href)

          parent = state.parent
          # .//P/C does not treat the context node as P. child::P never selects it.
          next if parent.nil? || parent.equal?(root)

          parent_state = parent.instance_variable_get(:@pure)
          next unless parent_state&.type == element
          next unless parent_state.name == parent_name && href_match?(parent_state, parent_href)

          out << node
          return out if limit && out.length >= limit
        end
        out
      end

      def self.named_children(root, parent_name, child_name, limit)
        if root.is_a?(XML::Document) && (flat = root.instance_variable_get(:@flat))
          return flat.named_children(parent_name, child_name, limit)
        end

        out = []
        each_element(root) do |_node, state|
          next unless state.name == parent_name && state.namespace.nil?

          append_children(state, child_name, out, limit)
          return out if limit && out.length >= limit
        end
        out
      end

      def self.named_attr_children(root, parent_name, attr_name, expected, child_name, limit)
        out = []
        each_element(root) do |_node, state|
          next unless state.name == parent_name && state.namespace.nil?
          next unless attr_match?(state, attr_name, expected)

          append_children(state, child_name, out, limit)
          return out if limit && out.length >= limit
        end
        out
      end

      def self.union_self(context, local, limit)
        out = []
        state = context.instance_variable_get(:@pure)
        if state&.type == XML::Node::ELEMENT_NODE && state.name == local && state.namespace.nil?
          out << context
          return out if limit && out.length >= limit
        end
        named(context, local, nil, limit.nil? ? nil : limit - out.length).each { |node| out << node }
        out
      end

      def self.append_children(state, local, out, limit)
        state.children.each do |child|
          child_state = child.instance_variable_get(:@pure)
          next unless child_state&.type == XML::Node::ELEMENT_NODE
          next unless child_state.name == local && child_state.namespace.nil?

          out << child
          return if limit && out.length >= limit
        end
      end

      def self.href_match?(state, href)
        if href.nil?
          state.namespace.nil?
        else
          state.namespace&.href == href
        end
      end

      def self.class_match?(state, needle)
        return true if needle.empty?

        state.attributes.each do |attr|
          attr_state = attr.instance_variable_get(:@pure)
          next unless attr_state&.name == "class" && attr_state.namespace.nil?

          return word_class?(attr_state.content.to_s, needle)
        end
        false
      end

      def self.attr_match?(state, name, expected)
        state.attributes.each do |attr|
          attr_state = attr.instance_variable_get(:@pure)
          next unless attr_state&.name == name && attr_state.namespace.nil?

          return attr_state.content.to_s == expected
        end
        expected == ""
      end

      def self.walk_elements(root, &block)
        each_element(root, &block)
      end

      def self.each_element(root)
        state = root.instance_variable_get(:@pure)
        return unless state

        children = state.children
        return if children.empty?

        stack = []
        index = children.length
        while index > 0
          index -= 1
          stack << children[index]
        end
        element = XML::Node::ELEMENT_NODE
        while (node = stack.pop)
          child_state = node.instance_variable_get(:@pure)
          next unless child_state

          yield node, child_state if child_state.type == element
          kids = child_state.children
          cursor = kids.length
          while cursor > 0
            cursor -= 1
            stack << kids[cursor]
          end
        end
      end

      # Word-boundary class match. Blank is space, tab, LF, and CR.
      def self.word_class?(hay, needle)
        return true if needle.empty?

        blank = " \t\n\r"
        index = 0
        while index < hay.length
          if hay[index, needle.length] == needle
            next_char = hay[index + needle.length]
            return true if next_char.nil? || blank.include?(next_char)
          end
          index += 1 while index < hay.length && !blank.include?(hay[index])
          index += 1 while index < hay.length && blank.include?(hay[index])
        end
        false
      end

      # One XPath value: a node set, a string, a number, or a boolean.
      class Value
        attr_reader :nodes, :text, :number, :type, :flag

        def self.nodes(list)
          new(:nodeset, nodes: list)
        end

        def self.text(string)
          new(:string, text: string.to_s)
        end

        def self.number(number)
          new(:number, number: number.to_f)
        end

        def self.bool(flag)
          new(:bool, flag: flag)
        end

        def initialize(type, nodes: nil, text: nil, number: nil, flag: nil)
          @type = type
          @nodes = nodes || []
          @text = text
          @number = number
          @flag = flag
        end

        def nodeset?
          @type == :nodeset
        end

        def number?
          @type == :number
        end

        def truthy
          case @type
          when :bool then @flag
          when :number then !@number.zero? && !@number.nan?
          when :string then !@text.empty?
          else !@nodes.empty?
          end
        end

        def to_s
          case @type
          when :string then @text
          when :bool then @flag ? "true" : "false"
          when :number then number_to_s(@number)
          else
            @nodes.empty? ? "" : XPath.string_value(@nodes.first)
          end
        end

        def to_number
          case @type
          when :number then @number
          when :bool then @flag ? 1.0 : 0.0
          else
            Float(to_s)
          end
        rescue ArgumentError, TypeError
          Float::NAN
        end

        private

        def number_to_s(number)
          return "NaN" if number.nan?
          return "Infinity" if number.infinite? == 1
          return "-Infinity" if number.infinite? == -1

          integer = number.to_i
          (integer == number) ? integer.to_s : number.to_s
        end
      end

      def self.string_value(node)
        return node.href.to_s if node.is_a?(XML::Namespace)

        node.content.to_s
      end

      # Evaluates one expression against one context node.
      class Engine
        def initialize(source, namespaces, variables, handler = nil, evaluating: true, node_limit: nil)
          @scanner = Scanner.new(source)
          @namespaces = namespaces
          @variables = variables
          @handler = handler
          @evaluating = evaluating
          @node_limit = node_limit
          @position = 1
          @size = 1
        end

        def evaluate(context_node, position: 1, size: 1)
          @context = context_node
          @position = position
          @size = size
          value = parse_or
          raise_syntax if @scanner.pending?
          value
        end

        private

        def parse_or
          left = parse_and
          while @scanner.keyword?("or")
            if @evaluating && left.truthy
              without_evaluation { parse_and }
            else
              right = parse_and
              left = Value.bool(left.truthy || right.truthy) if @evaluating
            end
          end
          left
        end

        def parse_and
          left = parse_equality
          while @scanner.keyword?("and")
            if @evaluating && !left.truthy
              without_evaluation { parse_equality }
            else
              right = parse_equality
              left = Value.bool(left.truthy && right.truthy) if @evaluating
            end
          end
          left
        end

        # Consume an expression without calling functions. XPath evaluates or/and lazily.
        def without_evaluation
          previous = @evaluating
          @evaluating = false
          yield
        ensure
          @evaluating = previous
        end

        def parse_equality
          left = parse_relational
          while (operator = @scanner.operator?("!=", "="))
            right = parse_relational
            left = Value.bool(equal?(left, right, operator))
          end
          left
        end

        def parse_relational
          left = parse_additive
          while (operator = @scanner.operator?("<=", ">=", "<", ">"))
            right = parse_additive
            left = Value.bool(relate?(left, right, operator))
          end
          left
        end

        def parse_additive
          left = parse_multiplicative
          while (operator = @scanner.operator?("+", "-"))
            right = parse_multiplicative
            number = (operator == "+") ? left.to_number + right.to_number : left.to_number - right.to_number
            left = Value.number(number)
          end
          left
        end

        def parse_multiplicative
          left = parse_unary
          while (operator = multiplicative_operator)
            right = parse_unary
            left = Value.number(multiply(left.to_number, right.to_number, operator))
          end
          left
        end

        def multiplicative_operator
          return "*" if @scanner.operator?("*")
          return "div" if @scanner.keyword?("div")
          return "mod" if @scanner.keyword?("mod")

          nil
        end

        def parse_unary
          if @scanner.operator?("-")
            Value.number(-parse_unary.to_number)
          else
            parse_union
          end
        end

        def parse_union
          left = parse_path_expr
          while @scanner.operator?("|")
            right = parse_path_expr
            left = Value.nodes(dedup(left.nodes + right.nodes))
            if @node_limit && left.nodes.length > @node_limit
              left = Value.nodes(left.nodes.take(@node_limit))
            end
          end
          left
        end

        def parse_path_expr
          if @scanner.location_path?
            Value.nodes(eval_location_path)
          else
            value = apply_value_predicates(parse_primary)
            (@scanner.peek == "/") ? continue_from_filter(value) : value
          end
        end

        # FilterExpr "/" RelativeLocationPath, including id("x")//foo.
        def continue_from_filter(value)
          steps = []
          if @scanner.double_slash?
            steps << node_step(:"descendant-or-self")
          else
            @scanner.slash?
          end
          steps.concat(parse_steps) if step_pending?
          Value.nodes(apply_steps(value.nodes, steps))
        end

        def parse_primary
          if @scanner.operator?("(")
            value = parse_or
            expect(")")
            value
          elsif (string = @scanner.string)
            Value.text(string)
          elsif (number = @scanner.number)
            Value.number(number)
          elsif @scanner.operator?("$")
            variable_value
          elsif (name = @scanner.function_qname)
            expect("(")
            args = parse_args
            expect(")")
            call_function(name, args)
          else
            raise_syntax
          end
        end

        def variable_value
          name = @scanner.ncname
          raise_syntax("undefined variable: #{name}") unless name && @variables.key?(name)

          Value.text(@variables[name].to_s)
        end

        def parse_args
          args = []
          return args if @scanner.peek == ")"

          loop do
            args << parse_or
            break unless @scanner.operator?(",")
          end
          args
        end

        def eval_location_path
          absolute = false
          steps = []
          if @scanner.double_slash?
            absolute = true
            steps << node_step(:"descendant-or-self")
          elsif @scanner.slash?
            absolute = true
          end
          steps.concat(parse_steps) if step_pending?
          nodes = if absolute
            [@context].map { |node| root_document(node) }
          else
            [@context]
          end
          apply_steps(nodes, steps)
        end

        def step_pending?
          return false if @scanner.eof?
          return false unless @scanner.location_path?
          return false if @scanner.peek_in?("|", "]", ")", ",", "=", "!", "<", ">", "+")

          true
        end

        def parse_steps
          steps = []
          loop do
            steps << parse_step
            if @scanner.double_slash?
              steps << node_step(:"descendant-or-self")
            elsif @scanner.slash?
              next
            else
              break
            end
            break unless step_pending?
          end
          steps
        end

        def parse_step
          if @scanner.operator?("@")
            axis = :attribute
            test = parse_node_test
          elsif @scanner.operator?("..")
            axis = :parent
            test = {kind: :node}
          elsif @scanner.operator?(".")
            axis = :self
            test = {kind: :node}
          else
            saved = @scanner.mark
            name = @scanner.ncname
            if name && @scanner.operator?("::")
              axis = name.to_sym
              test = parse_node_test
            else
              @scanner.rewind(saved)
              axis = :child
              test = parse_node_test
            end
          end
          predicates = []
          predicates << compile_predicate(@scanner.predicate) while @scanner.peek == "["
          {axis: axis, test: test, predicates: predicates}
        end

        def parse_node_test
          if @scanner.peek == ":" && @scanner.peek(2) != "::"
            @scanner.operator?(":")
            return {kind: :name, prefix: "", local: @scanner.ncname}
          end
          if @scanner.operator?("*")
            if @scanner.peek == ":" && @scanner.peek(2) != "::"
              @scanner.operator?(":")
              local = @scanner.ncname
              raise_syntax unless local

              return {kind: :name, prefix: "*", local: local}
            end
            return {kind: :star}
          end

          name = @scanner.ncname
          raise_syntax unless name

          if XPath::NODE_TESTS.include?(name) && @scanner.peek == "("
            @scanner.operator?("(")
            argument = nil
            argument = @scanner.string || @scanner.ncname unless @scanner.peek == ")"
            expect(")")
            return {kind: name.tr("-", "_").to_sym, argument: argument}
          end
          if @scanner.peek == ":" && @scanner.peek(2) != "::"
            @scanner.operator?(":")
            local = @scanner.operator?("*") ? "*" : @scanner.ncname
            return {kind: :name, prefix: name, local: local}
          end
          {kind: :name, prefix: nil, local: name}
        end

        def node_step(axis)
          {axis: axis, test: {kind: :node}, predicates: []}
        end

        # A single context node already yields these axes in document order.
        # Reverse axes come back nearest-first. Callers reverse them after predicates.
        FORWARD_AXES = {
          child: true,
          self: true,
          attribute: true,
          descendant: true,
          "descendant-or-self": true,
          "following-sibling": true
        }.freeze
        REVERSE_AXES = {
          parent: true,
          ancestor: true,
          "ancestor-or-self": true,
          "preceding-sibling": true
        }.freeze

        # CSS compiles //div[class] to descendant-or-self::node()/child::div[class].
        # The child step keeps its own position() scope. One context is already in document order.
        CLASS_CONTAINS = /\Acontains\(concat\(' ',normalize-space\(@([^)]+)\),' '\),' ([^']*)'\)\z/
        ATTR_EQUALS = /\A@([A-Za-z_][\w.-]*)=(?:"([^"]*)"|'([^']*)')\z/

        def apply_steps(nodes, steps)
          index = 0
          while index < steps.length
            step = steps[index]
            nxt = steps[index + 1]
            final = false
            if descendant_child_pair?(step, nxt)
              final = index + 2 == steps.length
              nodes = apply_descendant_child(nodes, nxt, limit: final ? @node_limit : nil)
              index += 2
            else
              final = index + 1 == steps.length
              nodes = apply_step(nodes, step, limit: final ? @node_limit : nil)
              index += 1
            end
            break if @node_limit && final && nodes.length >= @node_limit
          end
          nodes
        end

        def descendant_child_pair?(step, nxt)
          nxt &&
            step[:axis] == :"descendant-or-self" &&
            step[:test][:kind] == :node &&
            step[:predicates].empty? &&
            nxt[:axis] == :child
        end

        def apply_descendant_child(nodes, step, limit: nil)
          list = []
          if nodes.length == 1
            gather_descendant_children(nodes[0], step, list, limit)
            return list
          end

          nodes.each do |node|
            gather_descendant_children(node, step, list, limit)
            break if limit && list.length >= limit
          end
          return list if list.length < 2

          dedup(list)
        end

        def gather_descendant_children(node, step, out, limit)
          test = step[:test]
          if step[:predicates].empty? && test[:kind] == :name && test[:prefix].nil?
            gather_named_iter(node, test[:local], out, limit)
            return
          end

          state = node.instance_variable_get(:@pure)
          return unless state

          children = state.children
          return if children.empty?

          if step[:predicates].empty?
            children.each do |child|
              out << child if match_test?(child, test, :child)
              return if limit && out.length >= limit

              gather_descendant_children(child, step, out, limit)
              return if limit && out.length >= limit
            end
            return
          end

          matched = []
          # An unprefixed name test is the CSS and XPath case that walks every element.
          # Skip the general matcher. A literal local name of "*" keeps the old result.
          if test[:kind] == :name && test[:prefix].nil? && test[:local] != "*"
            local = test[:local]
            element = XML::Node::ELEMENT_NODE
            children.each do |child|
              child_state = child.instance_variable_get(:@pure)
              next unless child_state
              next unless child_state.type == element && child_state.name == local && child_state.namespace.nil?

              matched << child
            end
          else
            children.each { |child| matched << child if match_test?(child, test, :child) }
          end
          kept = apply_predicates(matched, step[:predicates])
          kept_ids = {}
          kept.each { |item| kept_ids[item.object_id] = true }
          children.each do |child|
            if kept_ids[child.object_id]
              out << child
              return if limit && out.length >= limit
            end
            gather_descendant_children(child, step, out, limit)
            return if limit && out.length >= limit
          end
        end

        # Preorder walk. One context emits matches in document order.
        def gather_named_iter(root, local, out, limit)
          state = root.instance_variable_get(:@pure)
          return unless state

          children = state.children
          return if children.empty?

          stack = []
          index = children.length
          while index > 0
            index -= 1
            stack << children[index]
          end
          element = XML::Node::ELEMENT_NODE
          while (node = stack.pop)
            child_state = node.instance_variable_get(:@pure)
            next unless child_state

            if child_state.type == element && child_state.name == local && child_state.namespace.nil?
              out << node
              return if limit && out.length >= limit
            end
            kids = child_state.children
            cursor = kids.length
            while cursor > 0
              cursor -= 1
              stack << kids[cursor]
            end
          end
        end

        def apply_step(nodes, step, limit: nil)
          axis = step[:axis]
          if nodes.length == 1 && (FORWARD_AXES[axis] || REVERSE_AXES[axis])
            found = axis_nodes(nodes[0], axis, step[:test])
            kept = apply_predicates(found, step[:predicates])
            return REVERSE_AXES[axis] ? kept.reverse : kept
          end

          matched = []
          nodes.each do |node|
            found = axis_nodes(node, axis, step[:test])
            matched.concat(apply_predicates(found, step[:predicates]))
          end
          dedup(matched)
        end

        def apply_predicates(nodes, predicates)
          current = nodes
          predicates.each do |source|
            current = filter_predicate(current, source)
          end
          current
        end

        # Compile a predicate once per step. The walk used to match these patterns
        # again for every parent node.
        def compile_predicate(source)
          if (match = CLASS_CONTAINS.match(source))
            name = match[1]
            inner = match[2]
            if !name.include?(":") && inner.length >= 2 && inner.start_with?(" ") && inner.end_with?(" ")
              needle = inner[1..-2]
              return {kind: :class, name: name, needle: needle} unless needle.include?(" ")
            end
          elsif (match = ATTR_EQUALS.match(source))
            name = match[1]
            unless name.include?(":")
              return {kind: :attr, name: name, expected: match[2] || match[3]}
            end
          end
          source
        end

        def filter_predicate(nodes, source)
          if source.is_a?(Hash)
            if source[:kind] == :class
              name = source[:name]
              needle = source[:needle]
              return nodes.select { |node| attribute_class?(node, name, needle) }
            end

            name = source[:name]
            expected = source[:expected]
            return nodes.select { |node| attribute_equals?(node, name, expected) }
          end

          if (match = CLASS_CONTAINS.match(source))
            name = match[1]
            inner = match[2]
            if !name.include?(":") && inner.length >= 2 && inner.start_with?(" ") && inner.end_with?(" ")
              needle = inner[1..-2]
              unless needle.include?(" ")
                return nodes.select { |node| attribute_class?(node, name, needle) }
              end
            end
          elsif (match = ATTR_EQUALS.match(source))
            name = match[1]
            unless name.include?(":")
              expected = match[2] || match[3]
              return nodes.select { |node| attribute_equals?(node, name, expected) }
            end
          end

          kept = []
          nodes.each_with_index do |node, index|
            value = child_engine(source).evaluate(node, position: index + 1, size: nodes.length)
            keep = value.number? ? value.number.to_i == index + 1 : value.truthy
            kept << node if keep
          end
          kept
        end

        def attribute_class?(node, name, needle)
          value = attribute_value(node, name)
          return needle.empty? unless value

          css_class?(value, needle)
        end

        def attribute_equals?(node, name, expected)
          value = attribute_value(node, name) || ""
          value == expected
        end

        def attribute_value(node, name)
          state = node.instance_variable_get(:@pure)
          return unless state

          state.attributes.each do |attr|
            attr_state = attr.instance_variable_get(:@pure)
            next unless attr_state&.name == name && attr_state.namespace.nil?

            return attr_state.content.to_s
          end
          nil
        end

        def apply_value_predicates(value)
          while @scanner.peek == "["
            source = @scanner.predicate
            nodes = value.nodes
            kept = []
            nodes.each_with_index do |node, index|
              inner = child_engine(source).evaluate(node, position: index + 1, size: nodes.length)
              keep = inner.number? ? inner.number.to_i == index + 1 : inner.truthy
              kept << node if keep
            end
            value = Value.nodes(kept)
          end
          value
        end

        def axis_nodes(node, axis, test)
          list = case axis
          when :child
            children_of(node)
          when :self
            [node]
          when :parent
            parent = parent_of(node)
            parent ? [parent] : []
          when :attribute
            state = node.instance_variable_get(:@pure)
            (state&.type == XML::Node::ELEMENT_NODE) ? state.attributes : []
          when :namespace
            namespace_axis(node)
          when :descendant
            collect_descendants(node, false)
          when :"descendant-or-self"
            collect_descendants(node, true)
          when :ancestor
            ancestors(node, false)
          when :"ancestor-or-self"
            ancestors(node, true)
          when :"following-sibling"
            siblings_from(node, 1)
          when :"preceding-sibling"
            siblings_from(node, -1)
          else
            raise_syntax("unknown axis #{axis}")
          end
          list.select { |item| match_test?(item, test, axis) }
        end

        def namespace_axis(node)
          return [] unless node.respond_to?(:element?) && node.element?

          scopes = node.namespace_scopes
          return scopes if scopes.any? { |ns| ns.prefix == "xml" }

          owner = node.respond_to?(:document) ? node.document : nil
          return scopes unless owner.respond_to?(:xml_namespace)

          [owner.xml_namespace, *scopes]
        end

        def children_of(node)
          state = node.instance_variable_get(:@pure)
          state ? state.children : []
        end

        def parent_of(node)
          state = node.instance_variable_get(:@pure)
          state&.parent
        end

        def collect_descendants(node, include_self)
          list = []
          list << node if include_self
          walk_children(node, list)
          list
        end

        def walk_children(node, list)
          state = node.instance_variable_get(:@pure)
          return unless state

          state.children.each do |child|
            list << child
            walk_children(child, list)
          end
        end

        def ancestors(node, include_self)
          list = []
          list << node if include_self
          current = parent_of(node)
          while current
            list << current
            current = parent_of(current)
          end
          list
        end

        def siblings_from(node, direction)
          parent = parent_of(node)
          parent_state = parent&.instance_variable_get(:@pure)
          return [] unless parent_state

          siblings = parent_state.children
          index = siblings.index(node)
          return [] unless index

          if direction.positive?
            siblings[(index + 1)..] || []
          else
            siblings[0...index].reverse
          end
        end

        def match_test?(node, test, axis)
          state = node.instance_variable_get(:@pure)
          case test[:kind]
          when :node
            !node.is_a?(XML::Namespace)
          when :text
            state&.type == XML::Node::TEXT_NODE || state&.type == XML::Node::CDATA_SECTION_NODE
          when :comment
            state&.type == XML::Node::COMMENT_NODE
          when :processing_instruction
            return false unless state&.type == XML::Node::PI_NODE

            test[:argument].nil? || state.name == test[:argument]
          when :star
            star_match?(node, state, axis)
          when :name
            name_match?(node, state, test, axis)
          else
            false
          end
        end

        def star_match?(node, state, axis)
          case axis
          when :attribute
            state&.type == XML::Node::ATTRIBUTE_NODE
          when :namespace
            node.is_a?(XML::Namespace)
          else
            state&.type == XML::Node::ELEMENT_NODE
          end
        end

        def name_match?(node, state, test, axis)
          if axis == :namespace
            return false unless node.is_a?(XML::Namespace)

            return node.prefix.to_s == test[:local].to_s
          end
          href_for(test[:prefix]) unless test[:prefix].nil? || test[:prefix] == "*"
          if axis == :attribute
            return false unless state&.type == XML::Node::ATTRIBUTE_NODE
          elsif state&.type != XML::Node::ELEMENT_NODE
            return false
          end
          return false unless test[:local] == "*" || state.name == test[:local]
          return true if test[:prefix] == "*"

          href = href_for(test[:prefix])
          if test[:prefix].nil?
            state.namespace.nil?
          else
            state.namespace&.href == href
          end
        end

        def href_for(prefix)
          return nil if prefix.nil?
          return @namespaces[""] if prefix.empty?
          return Pure::XML_NS_HREF if prefix == "xml" && !@namespaces.key?("xml")
          unless @namespaces.key?(prefix)
            raise XML::XPath::SyntaxError, "Undefined namespace prefix: #{prefix}"
          end

          @namespaces[prefix]
        end

        def child_engine(source)
          Engine.new(source, @namespaces, @variables, @handler, evaluating: @evaluating)
        end

        BUILTIN_FUNCTIONS = %w[
          contains concat normalize-space starts-with not count string-length substring
          position last true false boolean string number local-name namespace-uri name
          sum ceiling round floor id
        ].freeze

        def call_function(name, args)
          return Value.number(0) unless @evaluating

          prefix, local = split_qname(name)
          return call_builtin_extension(local, args) if prefix == "nokogiri-builtin"
          return call_builtin(local, args) if prefix.nil? && BUILTIN_FUNCTIONS.include?(local)
          if @handler&.respond_to?(local)
            if prefix.nil?
              warn("Invoking custom handler functions without a namespace is deprecated")
            end
            return handler_value(local, args)
          end

          call_builtin(local, args)
        end

        def split_qname(name)
          prefix, local = name.split(":", 2)
          return [nil, name] unless local

          [prefix, local]
        end

        def call_builtin(name, args)
          case name
          when "contains"
            Value.bool(args.fetch(0).to_s.include?(args.fetch(1).to_s))
          when "concat"
            Value.text(args.map(&:to_s).join)
          when "normalize-space"
            source = args.empty? ? XPath.string_value(@context) : args.fetch(0).to_s
            Value.text(source.strip.gsub(/[ \t\r\n]+/, " "))
          when "starts-with"
            Value.bool(args.fetch(0).to_s.start_with?(args.fetch(1).to_s))
          when "not"
            Value.bool(!args.fetch(0).truthy)
          when "count"
            Value.number(args.fetch(0).nodes.length)
          when "string-length"
            source = args.empty? ? XPath.string_value(@context) : args.fetch(0).to_s
            Value.number(source.length)
          when "substring"
            substring(args)
          when "position"
            Value.number(@position)
          when "last"
            Value.number(@size)
          when "true"
            Value.bool(true)
          when "false"
            Value.bool(false)
          when "boolean"
            Value.bool(args.fetch(0).truthy)
          when "string"
            Value.text(args.empty? ? XPath.string_value(@context) : args.fetch(0).to_s)
          when "number"
            Value.number(args.empty? ? numeric_value(XPath.string_value(@context)) : args.fetch(0).to_number)
          when "local-name"
            Value.text(named_node(args)&.name.to_s)
          when "namespace-uri"
            node = named_node(args)
            Value.text(node.respond_to?(:namespace) ? node.namespace&.href.to_s : "")
          when "name"
            Value.text(qualified_name(named_node(args)))
          when "sum"
            Value.number(xpath_sum(args.fetch(0)))
          when "ceiling"
            Value.number(xpath_ceiling(args.fetch(0).to_number))
          when "floor"
            Value.number(xpath_floor(args.fetch(0).to_number))
          when "round"
            Value.number(xpath_round(args.fetch(0).to_number))
          when "id"
            Value.nodes(id_nodes(args.fetch(0).to_s))
          else
            raise XML::XPath::SyntaxError, "xmlXPathCompOpEval: function #{name} not found"
          end
        end

        def call_builtin_extension(name, args)
          case name
          when "css-class"
            unless args.length == 2
              raise XML::XPath::SyntaxError, "xmlXPathCompOpEval: function css-class has wrong arity"
            end

            Value.bool(css_class?(args[0].to_s, args[1].to_s))
          when "local-name-is"
            unless args.length == 1
              raise XML::XPath::SyntaxError, "xmlXPathCompOpEval: function local-name-is has wrong arity"
            end

            Value.bool(@context.respond_to?(:name) && @context.name == args[0].to_s)
          else
            raise XML::XPath::SyntaxError, "xmlXPathCompOpEval: function #{name} not found"
          end
        end

        def css_class?(hay, needle)
          XPath.word_class?(hay, needle)
        end

        def handler_value(name, args)
          ruby_args = args.map { |arg| value_to_ruby(arg) }
          ruby_to_value(@handler.public_send(name, *ruby_args))
        end

        def value_to_ruby(value)
          case value.type
          when :nodeset
            XML::NodeSet.new(@context.document, value.nodes)
          when :bool
            value.flag
          when :number
            value.number
          else
            value.text
          end
        end

        def ruby_to_value(result)
          case result
          when nil
            Value.bool(false)
          when true, false
            Value.bool(result)
          when Numeric
            Value.number(result)
          when String
            Value.text(result)
          when XML::NodeSet
            Value.nodes(result.to_a)
          when Array
            Value.nodes(result.flatten.grep(XML::Node))
          else
            raise "Invalid return type"
          end
        end

        def xpath_sum(value)
          total = 0.0
          value.nodes.each do |node|
            number = numeric_value(XPath.string_value(node))
            return Float::NAN if number.nan?

            total += number
          end
          total
        end

        def numeric_value(text)
          Float(text)
        rescue ArgumentError, TypeError
          Float::NAN
        end

        def xpath_ceiling(number)
          return number unless number.finite?

          number.ceil.to_f
        end

        def xpath_floor(number)
          return number unless number.finite?

          number.floor.to_f
        end

        # XPath 1.0 round: ties go toward positive infinity.
        def xpath_round(number)
          return number unless number.finite?

          (number + 0.5).floor.to_f
        end

        def id_nodes(text)
          wanted = text.split(/\s+/).reject(&:empty?)
          return [] if wanted.empty?

          found = []
          walk = lambda do |node|
            if node.respond_to?(:element?) && node.element? && wanted.include?(node["id"])
              found << node
            end
            children_of(node).each { |child| walk.call(child) }
          end
          walk.call(root_document(@context))
          found
        end

        def substring(args)
          source = args.fetch(0).to_s
          start = args.fetch(1).to_number.round - 1
          return Value.text("") if start.negative? || start >= source.length

          if args[2]
            length = args[2].to_number.round
            Value.text(source[start, length].to_s)
          else
            Value.text(source[start..].to_s)
          end
        end

        def named_node(args)
          return @context if args.empty?

          args.fetch(0).nodes.first
        end

        def qualified_name(node)
          return "" unless node.respond_to?(:name)

          prefix = node.namespace&.prefix if node.respond_to?(:namespace)
          if prefix && !prefix.empty?
            "#{prefix}:#{node.name}"
          else
            node.name.to_s
          end
        end

        def equal?(left, right, operator)
          pairs = comparison_pairs(left, right)
          if operator == "="
            pairs.any? { |lhs, rhs| same_value?(left, right, lhs, rhs) }
          else
            pairs.any? { |lhs, rhs| !same_value?(left, right, lhs, rhs) }
          end
        end

        def same_value?(left, right, lhs, rhs)
          if left.number? || right.number?
            lhs.to_number == rhs.to_number
          else
            lhs.to_s == rhs.to_s
          end
        end

        def relate?(left, right, operator)
          left_number = left.to_number
          right_number = right.to_number
          case operator
          when "<" then left_number < right_number
          when ">" then left_number > right_number
          when "<=" then left_number <= right_number
          else left_number >= right_number
          end
        end

        def comparison_pairs(left, right)
          return [] if left.nodeset? && left.nodes.empty?
          return [] if right.nodeset? && right.nodes.empty?

          left_values = left.nodeset? ? left.nodes.map { |node| Value.text(XPath.string_value(node)) } : [left]
          right_values = right.nodeset? ? right.nodes.map { |node| Value.text(XPath.string_value(node)) } : [right]
          left_values.product(right_values)
        end

        def multiply(left, right, operator)
          case operator
          when "*" then left * right
          when "div" then left / right
          else
            return Float::NAN if right.zero?

            left.divmod(right).last
          end
        end

        def root_document(node)
          return node if node.is_a?(XML::Document)
          return node.document if node.respond_to?(:document) && node.document

          node
        end

        def dedup(nodes)
          seen = {}
          list = []
          nodes.each do |node|
            id = node.object_id
            next if seen[id]

            seen[id] = true
            list << node
          end
          sort_document_order(list)
        end

        # Array#index inside Node#compare makes a comparison sort quadratic on a wide tree.
        # Small sets use a parent-chain key. Large sets use one preorder stamp.
        def sort_document_order(list)
          return list if list.length < 2

          root = order_root(list[0])
          list.each { |node| return compare_sort(list) unless order_root(node).equal?(root) }
          return sort_by_stamp(list, root) if list.length >= 64

          sort_by_keys(list)
        end

        def sort_by_keys(list)
          prepare_order_cache
          keys = Array.new(list.length)
          list.each_with_index do |node, index|
            key = order_key(node)
            return compare_sort(list) unless key

            keys[index] = key
          end
          list.sort_by!.with_index { |_, index| keys[index] }
        end

        def sort_by_stamp(list, root)
          index = stamp_index(root)
          return compare_sort(list) unless list.all? { |node| index.key?(node.object_id) }

          list.sort_by! { |node| index[node.object_id] }
        end

        def prepare_order_cache
          @order_keys ||= {}
          @child_indexes ||= {}
          @attr_indexes ||= {}
        end

        def order_key(node)
          id = node.object_id
          return @order_keys[id] if @order_keys.key?(id)

          state = node.instance_variable_get(:@pure)
          return @order_keys[id] = nil unless state

          parent = state.parent
          return @order_keys[id] = [] unless parent

          parent_key = order_key(parent)
          return @order_keys[id] = nil unless parent_key

          slot = if state.type == XML::Node::ATTRIBUTE_NODE
            attribute_index(parent, id)
          else
            child_index(parent, id)
          end
          return @order_keys[id] = nil unless slot

          @order_keys[id] = parent_key + slot
        end

        def child_index(parent, child_id)
          cache = @child_indexes[parent.object_id]
          unless cache
            cache = {}
            parent_state = parent.instance_variable_get(:@pure)
            parent_state.children.each_with_index { |child, index| cache[child.object_id] = index }
            @child_indexes[parent.object_id] = cache
          end
          index = cache[child_id]
          index && [1, index]
        end

        def attribute_index(parent, attr_id)
          cache = @attr_indexes[parent.object_id]
          unless cache
            cache = {}
            parent_state = parent.instance_variable_get(:@pure)
            parent_state.attributes.each_with_index { |attr, index| cache[attr.object_id] = index }
            @attr_indexes[parent.object_id] = cache
          end
          index = cache[attr_id]
          index && [0, index]
        end

        def stamp_index(root)
          return @stamp_index if @stamp_root.equal?(root) && @stamp_index

          index = {}
          counter = 0
          walk = lambda do |node|
            counter += 1
            index[node.object_id] = counter
            state = node.instance_variable_get(:@pure)
            return unless state

            state.attributes.each do |attr|
              counter += 1
              index[attr.object_id] = counter
            end
            state.children.each { |child| walk.call(child) }
          end
          walk.call(root)
          @stamp_root = root
          @stamp_index = index
        end

        def compare_sort(list)
          list.sort! { |left, right| node_order(left, right) }
        end

        def order_root(node)
          current = node
          guard = 0
          while guard < 10_000
            state = current.instance_variable_get(:@pure)
            parent = state&.parent
            break unless parent

            current = parent
            guard += 1
          end
          current
        end

        # XPath node-sets are returned in document order. position() uses axis order
        # before this sort.
        def node_order(left, right)
          return 0 if left.equal?(right)
          return 0 unless left.respond_to?(:compare) && right.is_a?(XML::Node)

          left.compare(right) || 0
        end

        def expect(token)
          return if @scanner.operator?(token)

          raise_syntax
        end

        def raise_syntax(detail = nil)
          @scanner.syntax_error!(detail)
        end
      end

      # Token reader for one XPath expression.
      class Scanner
        def initialize(source)
          @source = source
          @index = 0
          @slash_consumed = false
          @ascii = source.ascii_only?
        end

        attr_reader :slash_consumed

        def eof?
          skip_space
          @index >= @source.length
        end

        def pending?
          !eof?
        end

        def peek(length = 1)
          skip_space
          return "" if @index >= @source.length

          @source[@index, length].to_s
        end

        def peek_in?(*tokens)
          tokens.include?(peek)
        end

        def mark
          @index
        end

        def rewind(index)
          @index = index
        end

        def operator?(*tokens)
          skip_space
          tokens.each do |token|
            next unless starts_with?(token)

            @index += token.length
            @slash_consumed = token == "/"
            return token
          end
          false
        end

        def starts_with?(token)
          unless @ascii
            return @source[@index, token.length] == token
          end

          base = @index
          size = token.bytesize
          return false if base + size > @source.bytesize

          cursor = 0
          while cursor < size
            return false unless @source.getbyte(base + cursor) == token.getbyte(cursor)

            cursor += 1
          end
          true
        end

        def keyword?(word)
          return false unless keyword_ahead?(word)

          @index += word.length
          true
        end

        def keyword_ahead?(word)
          skip_space
          return false unless starts_with?(word)

          if @ascii
            next_byte = @source.getbyte(@index + word.bytesize)
            return true unless next_byte

            return !name_byte?(next_byte)
          end

          next_char = @source[@index + word.length]
          !(next_char && next_char.match?(/[\p{L}\p{N}_.-]/))
        end

        def name_byte?(byte)
          (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            byte == 95 || byte == 46 || byte == 45
        end

        def location_path?
          character = peek
          return false if character.empty?
          return true if "/.@*:".include?(character)

          saved = @index
          name = ncname
          path = if name.nil?
            false
          elsif peek == ":" && peek(2) != "::"
            @index += 1
            local = ncname
            !(local && peek == "(")
          elsif peek == "("
            XPath::NODE_TESTS.include?(name)
          else
            true
          end
          @index = saved
          path
        end

        # A function call is an NCName or a QName, including hyphenated names, then "(".
        def function_qname
          skip_space
          saved = @index
          first = ncname
          unless first
            @index = saved
            return
          end
          if peek == ":" && peek(2) != "::"
            @index += 1
            local = ncname
            if local && peek == "("
              return "#{first}:#{local}"
            end

            @index = saved
            return
          end
          return first if peek == "("

          @index = saved
          nil
        end

        def double_slash?
          skip_space
          return false unless @source[@index, 2] == "//"

          @index += 2
          @slash_consumed = true
          true
        end

        def slash?
          return false if peek(2) == "//"

          operator?("/")
        end

        def string
          skip_space
          quote = @source[@index]
          return unless quote == "'" || quote == '"'

          @index += 1
          start = @index
          @index += 1 while @index < @source.length && @source[@index] != quote
          syntax_error! if @index >= @source.length

          value = @source[start...@index]
          @index += 1
          value
        end

        NUMBER = /\G\d+(?:\.\d+)?/
        NCNAME = /\G[\p{L}_][\p{L}\p{N}_.-]*/

        def number
          skip_space
          match = NUMBER.match(@source, @index)
          return unless match

          @index = match.end(0)
          match[0].to_f
        end

        def ncname
          skip_space
          match = NCNAME.match(@source, @index)
          return unless match

          @index = match.end(0)
          match[0]
        end

        def predicate
          syntax_error! unless operator?("[")

          start = @index
          depth = 1
          quote = nil
          while depth.positive? && @index < @source.length
            character = @source[@index]
            if quote
              quote = nil if character == quote
            elsif character == "'" || character == '"'
              quote = character
            elsif character == "["
              depth += 1
            elsif character == "]"
              depth -= 1
              break if depth.zero?
            end
            @index += 1
          end
          syntax_error! unless depth.zero?

          body = @source[start...@index]
          @index += 1
          body
        end

        def syntax_error!(detail = nil)
          message = detail ? "Invalid expression: #{detail}" : "Invalid expression"
          raise XML::XPath::SyntaxError, "#{message}: #{@source}"
        end

        private

        def skip_space
          source = @source
          length = @ascii ? source.bytesize : source.length
          index = @index
          while index < length
            ord = @ascii ? source.getbyte(index) : source[index].ord
            if ord == 32 || ord == 9 || ord == 10 || ord == 13 || ord == 12 || ord == 11
              index += 1
            elsif !@ascii && ord > 127 && source[index].match?(/\s/)
              index += 1
            else
              break
            end
          end
          @index = index
        end
      end
    end
  end

  module XML
    class XPathContext
      def self.new(node)
        context = allocate
        context.instance_variable_set(:@node, node)
        context.instance_variable_set(:@namespaces, {"xml" => Pure::XML_NS_HREF})
        context.instance_variable_set(:@variables, {})
        context
      end

      def register_ns(prefix, uri)
        key = prefix.to_s
        key = "" if key == "xmlns"
        if uri.nil?
          @namespaces.delete(key)
        else
          @namespaces[key] = uri.to_s
        end
      end

      def register_variable(key, value)
        if value.nil?
          @variables.delete(key.to_s)
        else
          @variables[key.to_s] = value
        end
      end

      attr_writer :node

      def evaluate(path, handler = nil)
        Pure::XPath.evaluate(@node, path, @namespaces, @variables, handler)
      end
    end
  end
end
