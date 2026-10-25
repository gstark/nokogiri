# frozen_string_literal: true

module Nokogiri
  module Pure
    # XPath 1.0 subset used by the pure backend.
    #
    # Covers location paths, the axes CSS and the document tests need, and the
    # functions the CSS compiler emits.
    class XPath
      NODE_TESTS = %w[text node comment processing-instruction].freeze

      def self.evaluate(context_node, path, namespaces, variables = nil, handler = nil)
        value = Engine.new(path.to_s, namespaces || {}, variables || {}, handler).evaluate(context_node)
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
          integer == number ? integer.to_s : number.to_s
        end
      end

      def self.string_value(node)
        return node.href.to_s if node.is_a?(XML::Namespace)

        node.content.to_s
      end

      # Evaluates one expression against one context node.
      class Engine
        def initialize(source, namespaces, variables, handler = nil, evaluating: true)
          @scanner = Scanner.new(source)
          @namespaces = namespaces
          @variables = variables
          @handler = handler
          @evaluating = evaluating
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
            number = operator == "+" ? left.to_number + right.to_number : left.to_number - right.to_number
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
          end
          left
        end

        def parse_path_expr
          if @scanner.location_path?
            Value.nodes(eval_location_path)
          else
            value = apply_value_predicates(parse_primary)
            @scanner.peek == "/" ? continue_from_filter(value) : value
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
            test = { kind: :node }
          elsif @scanner.operator?(".")
            axis = :self
            test = { kind: :node }
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
          predicates << @scanner.predicate while @scanner.peek == "["
          { axis: axis, test: test, predicates: predicates }
        end

        def parse_node_test
          if @scanner.peek == ":" && @scanner.peek(2) != "::"
            @scanner.operator?(":")
            return { kind: :name, prefix: "", local: @scanner.ncname }
          end
          if @scanner.operator?("*")
            return { kind: :star }
          end

          name = @scanner.ncname
          raise_syntax unless name

          if XPath::NODE_TESTS.include?(name) && @scanner.peek == "("
            @scanner.operator?("(")
            argument = nil
            argument = @scanner.string || @scanner.ncname unless @scanner.peek == ")"
            expect(")")
            return { kind: name.tr("-", "_").to_sym, argument: argument }
          end
          if @scanner.peek == ":" && @scanner.peek(2) != "::"
            @scanner.operator?(":")
            local = @scanner.operator?("*") ? "*" : @scanner.ncname
            return { kind: :name, prefix: name, local: local }
          end
          { kind: :name, prefix: nil, local: name }
        end

        def node_step(axis)
          { axis: axis, test: { kind: :node }, predicates: [] }
        end

        def apply_steps(nodes, steps)
          steps.each do |step|
            nodes = apply_step(nodes, step)
          end
          nodes
        end

        def apply_step(nodes, step)
          matched = []
          nodes.each do |node|
            found = axis_nodes(node, step[:axis], step[:test])
            matched.concat(apply_predicates(found, step[:predicates]))
          end
          dedup(matched)
        end

        def apply_predicates(nodes, predicates)
          current = nodes
          predicates.each do |source|
            kept = []
            current.each_with_index do |node, index|
              value = child_engine(source).evaluate(node, position: index + 1, size: current.length)
              keep = value.number? ? value.number.to_i == index + 1 : value.truthy
              kept << node if keep
            end
            current = kept
          end
          current
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
            node.respond_to?(:element?) && node.element? ? node.pure.attributes : []
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
          return [] unless node.respond_to?(:pure)

          node.pure.children
        end

        def parent_of(node)
          return unless node.respond_to?(:parent)

          node.parent
        end

        def collect_descendants(node, include_self)
          list = []
          list << node if include_self
          walk_children(node, list)
          list
        end

        def walk_children(node, list)
          return unless node.respond_to?(:pure)

          node.pure.children.each do |child|
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
          return [] unless parent&.respond_to?(:pure)

          siblings = parent.pure.children
          index = siblings.index(node)
          return [] unless index

          if direction.positive?
            siblings[(index + 1)..] || []
          else
            siblings[0...index].reverse
          end
        end

        def match_test?(node, test, axis)
          case test[:kind]
          when :node
            !node.is_a?(XML::Namespace)
          when :text
            node.respond_to?(:text?) && node.text?
          when :comment
            node.respond_to?(:comment?) && node.comment?
          when :processing_instruction
            return false unless node.respond_to?(:processing_instruction?) && node.processing_instruction?

            test[:argument].nil? || node.name == test[:argument]
          when :star
            star_match?(node, axis)
          when :name
            name_match?(node, test, axis)
          else
            false
          end
        end

        def star_match?(node, axis)
          case axis
          when :attribute
            node.respond_to?(:node_type) && node.node_type == XML::Node::ATTRIBUTE_NODE
          when :namespace
            node.is_a?(XML::Namespace)
          else
            node.respond_to?(:element?) && node.element?
          end
        end

        def name_match?(node, test, axis)
          if axis == :namespace
            return false unless node.is_a?(XML::Namespace)

            return node.prefix.to_s == test[:local].to_s
          end
          href_for(test[:prefix]) unless test[:prefix].nil?
          if axis == :attribute
            return false unless node.respond_to?(:node_type) && node.node_type == XML::Node::ATTRIBUTE_NODE
          elsif !node.respond_to?(:element?) || !node.element?
            return false
          end
          return false unless node.name == test[:local]
          return test[:prefix] == "*" if test[:local] == "*"

          href = href_for(test[:prefix])
          if test[:prefix].nil?
            node.namespace.nil?
          else
            node.namespace&.href == href
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
          return handler_value(local, args) if @handler&.respond_to?(local)

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

        # Word-boundary class match. Blank is space, tab, LF, and CR.
        def css_class?(hay, needle)
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
            raise RuntimeError, "Invalid return type"
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
          list = nodes.each_with_object([]) do |node, collected|
            next if seen[node.object_id]

            seen[node.object_id] = true
            collected << node
          end
          sort_document_order(list)
        end

        # Array#index inside Node#compare makes a comparison sort quadratic on a wide tree.
        # One document-order walk is enough when every node hangs from the same root.
        def sort_document_order(list)
          return list if list.length < 2

          root = order_root(list.first)
          return compare_sort(list) unless list.all? { |node| order_root(node).equal?(root) }

          wanted = {}
          list.each { |node| wanted[node.object_id] = true }
          ordered = []
          collect_in_order(root, wanted, ordered)
          return ordered if ordered.length == list.length

          compare_sort(list)
        end

        def compare_sort(list)
          list.sort! { |left, right| node_order(left, right) }
        end

        def order_root(node)
          current = node
          guard = 0
          while current.respond_to?(:parent) && guard < 10_000
            parent = current.parent
            break if parent.nil?

            current = parent
            guard += 1
          end
          current
        end

        def collect_in_order(node, wanted, ordered)
          ordered << node if wanted[node.object_id]
          return unless node.respond_to?(:pure)

          node.pure.attributes.each do |attr|
            ordered << attr if wanted[attr.object_id]
          end
          node.pure.children.each { |child| collect_in_order(child, wanted, ordered) }
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
            next unless @source[@index, token.length] == token

            @index += token.length
            @slash_consumed = token == "/"
            return token
          end
          false
        end

        def keyword?(word)
          return false unless keyword_ahead?(word)

          @index += word.length
          true
        end

        def keyword_ahead?(word)
          skip_space
          return false unless @source[@index, word.length] == word

          next_char = @source[@index + word.length]
          !(next_char && next_char.match?(/[\p{L}\p{N}_.\-]/))
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

        def number
          skip_space
          match = @source[@index..].match(/\A\d+(?:\.\d+)?/)
          return unless match

          @index += match[0].length
          match[0].to_f
        end

        def ncname
          skip_space
          match = @source[@index..].match(/\A[\p{L}_][\p{L}\p{N}_.\-]*/)
          return unless match

          @index += match[0].length
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
          @index += 1 while @index < @source.length && @source[@index].match?(/\s/)
        end
      end
    end
  end

  module XML
    class XPathContext
      def self.new(node)
        context = allocate
        context.instance_variable_set(:@node, node)
        context.instance_variable_set(:@namespaces, { "xml" => Pure::XML_NS_HREF })
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

      def node=(node)
        @node = node
      end

      def evaluate(path, handler = nil)
        Pure::XPath.evaluate(@node, path, @namespaces, @variables, handler)
      end
    end
  end
end
