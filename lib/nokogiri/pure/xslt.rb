# frozen_string_literal: true

module Nokogiri
  module Pure
    # XSLT 1.0 subset used by the pure backend.
    #
    # Covers the instructions the pure-Ruby suite executes: output, param,
    # template, apply-templates, copy, copy-of, choose, for-each, value-of,
    # text, and strip-space. EXSLT func:function, math:max, and date:date are
    # included because the suite calls them.
    class XsltEngine
      XSLT_NS = "http://www.w3.org/1999/XSL/Transform"
      FUNC_NS = "http://exslt.org/functions"
      MATH_NS = "http://exslt.org/math"
      DATE_NS = "http://exslt.org/dates-and-times"
      TOP_LEVEL = %w[
        import include strip-space preserve-space output key decimal-format
        attribute-set variable param template namespace-alias
      ].freeze

      Context = Struct.new(:node, :variables, :result)

      # A compile check knows no variable values, so it accepts every name.
      module AnyVariable
        def self.key?(_name) = true

        def self.[](_name) = ""
      end

      # Dispatches namespaced extension calls. XPath asks only for the local name.
      class Extensions
        def initialize(engine)
          @engine = engine
        end

        def respond_to_missing?(name, _include_private = false)
          @engine.extension?(name.to_s)
        end

        def method_missing(name, *args)
          @engine.invoke_extension(name.to_s, args)
        end
      end

      def self.compile(document)
        engine = new
        engine.compile(document)
        engine
      end

      def initialize
        @output_method = nil
        @output_version = nil
        @output_encoding = nil
        @params = []
        @templates = []
        @namespaces = {}
        @functions = {}
        @strip_names = []
        @instances = {}
        @caller = Extensions.new(self)
        @xpath_context = nil
        @strip_restores = nil
      end

      def compile(document)
        root = document.root
        unless xsl?(root) && %w[stylesheet transform].include?(root.name)
          raise "invalid stylesheet"
        end

        root.namespace_scopes.each do |ns|
          @namespaces[ns.prefix] = ns.href if ns.prefix && !ns.prefix.empty?
        end

        root.pure.children.each do |child|
          next unless child.element?
          if function_element?(child)
            compile_function(child)
            next
          end
          unless xsl?(child) && TOP_LEVEL.include?(child.name)
            raise "element #{child.name} is not allowed in an XSLT stylesheet"
          end

          compile_top(child)
        end
        self
      end

      def extension?(name)
        return true if @functions.key?(name)
        return true if name == "max" && namespace_used?(MATH_NS)
        return true if name == "date" && namespace_used?(DATE_NS)

        !handler_class_for(name).nil?
      end

      def invoke_extension(name, args)
        if (select = @functions[name])
          return evaluate(@xpath_context, select, {})
        end
        return exslt_max(args.first) if name == "max" && namespace_used?(MATH_NS)
        return Time.now.utc.strftime("%Y-%m-%d") if name == "date" && namespace_used?(DATE_NS)

        klass = handler_class_for(name)
        raise NoMethodError, "undefined method `#{name}'" unless klass

        handler_instance(klass).public_send(name, *args)
      end

      def transform(document, params)
        apply_strip_space(document)
        variables = {}
        @params.each do |name, expression|
          variables[name] = expression ? string_value(document, expression, variables) : ""
        end
        params.each_slice(2) do |name, expression|
          variables[name.to_s] = string_value(document, expression.to_s, variables)
        end

        result = XML::Document.new(@output_version || "1.0")
        result.encoding = @output_encoding if @output_encoding
        apply_one(document, Context.new(document, variables, result), result, nil)
        result.pure.type = XML::Node::HTML_DOCUMENT_NODE if html_output?(result)
        result
      ensure
        restore_strip_space
      end

      def serialize(document)
        return document.content.to_s if @output_method == "text"
        return document.to_html if html_output?(document)

        document.to_xml
      end

      private

      def compile_top(node)
        case node.name
        when "output"
          @output_method = node["method"] if node["method"]
          @output_version = node["version"] if node["version"]
          @output_encoding = node["encoding"] if node["encoding"]
        when "param"
          @params << [node["name"].to_s, node["select"]]
        when "template"
          priority = node["priority"]
          mode = node["mode"]
          @templates << {
            match: node["match"].to_s,
            mode: (mode.nil? || mode.empty?) ? nil : mode,
            priority: (priority.nil? || priority.empty?) ? nil : Float(priority),
            body: compile_sequence(node)
          }
        when "strip-space"
          @strip_names.concat(node["elements"].to_s.split)
        end
      end

      def compile_function(node)
        qname = node["name"].to_s
        local = qname.split(":", 2).last
        result = node.pure.children.find { |child| child.element? && child.name == "result" }
        @functions[local] = result ? result["select"].to_s : "''"
      end

      def compile_sequence(node)
        node.pure.children.filter_map { |child| compile_instruction(child) }
      end

      def compile_instruction(node)
        if node.text?
          return if node.blank?

          return [:text, node.content, false]
        end
        return unless node.element?
        return compile_xsl(node) if xsl?(node)

        attributes = node.pure.attributes.map { |attr| [attr.name, attr.content.to_s] }
        [:element, node.name, attributes, compile_sequence(node)]
      end

      def compile_xsl(node)
        case node.name
        when "value-of"
          [:value_of, compiled_select(node)]
        when "for-each"
          [:for_each, compiled_select(node), compile_sequence(node)]
        when "text"
          [:text, node.content.to_s, node["disable-output-escaping"] == "yes"]
        when "apply-templates"
          mode = node["mode"]
          [:apply_templates, compiled_select(node), (mode.nil? || mode.empty?) ? nil : mode]
        when "apply-imports"
          [:apply_imports]
        when "copy"
          [:copy, compile_sequence(node)]
        when "copy-of"
          [:copy_of, compiled_select(node)]
        when "choose"
          [:choose, node.pure.children.filter_map { |child| compile_branch(child) }]
        end
      end

      # libxml2 compiles each expression when it loads the stylesheet, and
      # a syntax error stops the load.
      def compiled_select(node, attribute = "select")
        expression = node[attribute].to_s
        return expression if expression.empty?

        Pure::XPath::Engine.new(expression, @namespaces, AnyVariable, evaluating: false).evaluate(node.document)
        expression
      rescue XML::XPath::SyntaxError
        raise "compilation error: element #{node.name}\nxsl:#{node.name} : could not compile #{attribute} expression '#{expression}'"
      end

      def compile_branch(node)
        return unless node.element? && xsl?(node)

        case node.name
        when "when"
          [:when, compiled_select(node, "test"), compile_sequence(node)]
        when "otherwise"
          [:otherwise, compile_sequence(node)]
        end
      end

      def execute(instructions, ctx, parent)
        instructions.each do |instruction|
          case instruction[0]
          when :text
            append_text(parent, ctx, instruction[1], instruction[2])
          when :element
            element = ctx.result.create_element(instruction[1])
            instruction[2].each { |name, value| element[name] = value }
            append_node(parent, element)
            execute(instruction[3], ctx, element)
          when :value_of
            append_text(parent, ctx, string_value(ctx.node, instruction[1], ctx.variables), false)
          when :for_each
            node_set(ctx.node, instruction[1], ctx.variables).each do |node|
              execute(instruction[2], Context.new(node, ctx.variables, ctx.result), parent)
            end
          when :apply_templates
            select = instruction[1]
            select = "node()" if select.empty?
            node_set(ctx.node, select, ctx.variables).each do |node|
              apply_one(node, ctx, parent, instruction[2])
            end
          when :apply_imports
            nil
          when :copy
            copy_current(ctx.node, parent, ctx, instruction[1])
          when :copy_of
            insert_copy_of(parent, ctx, evaluate(ctx.node, instruction[1], ctx.variables))
          when :choose
            instruction[1].each do |branch|
              next unless branch[0] == :otherwise || test_true?(branch[1], ctx)

              execute(branch.last, ctx, parent)
              break
            end
          end
        end
      end

      def apply_one(node, ctx, parent, mode)
        return if node.node_type == XML::Node::DTD_NODE

        template = find_template(node, mode)
        child = Context.new(node, ctx.variables, ctx.result)
        if template
          execute(template[:body], child, parent)
        else
          builtin_template(node, child, parent, mode)
        end
      end

      def builtin_template(node, ctx, parent, mode)
        if node.document? || node.element?
          node.pure.children.each { |child| apply_one(child, ctx, parent, mode) }
        elsif node.text? || node.cdata?
          text = node.pure.content.to_s
          append_text(parent, ctx, text, false) unless text.empty?
        elsif attribute_node?(node)
          append_text(parent, ctx, node.pure.content.to_s, false)
        end
      end

      def find_template(node, mode)
        best = nil
        best_priority = nil
        best_index = -1
        @templates.each_with_index do |template, index|
          next unless template[:mode] == mode

          priority = template_priority(template, node)
          next if priority.nil?
          better = best.nil? || priority > best_priority || (priority == best_priority && index > best_index)
          next unless better

          best = template
          best_priority = priority
          best_index = index
        end
        best
      end

      def template_priority(template, node)
        matched = nil
        split_union(template[:match]).each do |part|
          next unless matches_alternative?(part, node)

          score = alternative_priority(part)
          matched = score if matched.nil? || score > matched
        end
        return if matched.nil?

        template[:priority] || matched
      end

      def alternative_priority(pattern)
        pattern = pattern.strip
        return 0.5 if pattern == "/" || pattern.include?("/")

        step = pattern.start_with?("@") ? pattern[1..] : pattern
        return -0.5 if ["*", "node()", "text()", "comment()"].include?(step) || step.start_with?("processing-instruction(")
        return -0.25 if step.end_with?(":*")

        0
      end

      def matches_alternative?(pattern, node)
        pattern = pattern.strip
        return node.document? if pattern == "/"
        return false if pattern.empty?

        absolute = pattern.start_with?("/")
        steps = pattern.sub(%r{\A/+}, "").split("/")
        return false if steps.empty?

        matches_steps?(steps, node, absolute)
      end

      def matches_steps?(steps, node, absolute)
        return false if node.nil?
        return false unless matches_step?(steps.last, node)
        return true if steps.length == 1 && !absolute

        parent = pattern_parent(node)
        if steps.length == 1
          parent.nil? || parent.document?
        else
          matches_steps?(steps[0..-2], parent, absolute)
        end
      end

      def matches_step?(step, node)
        return false if node.is_a?(XML::Namespace)

        if step.start_with?("@")
          return false unless attribute_node?(node)

          return attribute_step?(node, step[1..])
        end
        return false if attribute_node?(node)

        case step
        when "node()" then true
        when "text()" then node.text? || node.cdata?
        when "comment()" then node.comment?
        when "*" then node.element?
        else node.element? && qname_matches?(node, step)
        end
      end

      def attribute_step?(node, step)
        return true if step == "*"

        qname_matches?(node, step)
      end

      def qname_matches?(node, qname)
        if (index = qname.index(":"))
          prefix = qname[0...index]
          local = qname[(index + 1)..]
          return false unless node.name == local

          href = @namespaces[prefix]
          return false if href.nil?

          node.namespace&.href == href
        else
          node.name == qname && node.namespace.nil?
        end
      end

      def pattern_parent(node)
        return if node.document?

        node.parent
      end

      def split_union(pattern)
        parts = []
        current = +""
        quote = nil
        pattern.each_char do |char|
          if quote
            current << char
            quote = nil if char == quote
          elsif char == "'" || char == '"'
            quote = char
            current << char
          elsif char == "|"
            parts << current.strip
            current = +""
          else
            current << char
          end
        end
        parts << current.strip
        parts.reject(&:empty?)
      end

      def copy_current(node, parent, ctx, body)
        if node.document?
          execute(body, ctx, parent)
        elsif node.element?
          element = ctx.result.create_element(node.name)
          append_node(parent, element)
          copy_namespaces(node, element)
          execute(body, ctx, element)
        elsif node.text? || node.cdata?
          append_text(parent, ctx, node.pure.content.to_s, false)
          execute(body, ctx, parent)
        elsif node.comment?
          append_node(parent, ctx.result.create_comment(node.pure.content.to_s))
          execute(body, ctx, parent)
        elsif attribute_node?(node)
          copy_attribute(node, parent)
          execute(body, ctx, parent)
        else
          execute(body, ctx, parent)
        end
      end

      def copy_namespaces(source, element)
        source.namespace_scopes.each do |ns|
          next if ns.prefix == "xml"

          element.add_namespace_definition(ns.prefix, ns.href)
        end
        return if source.namespace.nil?

        match = element.namespace_definitions.find { |ns|
          ns.prefix == source.namespace.prefix && ns.href == source.namespace.href
        }
        element.namespace = match if match
      end

      def copy_attribute(node, parent)
        return unless parent.element?

        prefix = node.namespace&.prefix
        qname = (prefix && !prefix.empty?) ? "#{prefix}:#{node.name}" : node.name
        parent[qname] = node.pure.content.to_s
      end

      def insert_copy_of(parent, ctx, value)
        case value
        when XML::NodeSet
          value.each { |node| deep_copy(node, parent, ctx) }
        else
          append_text(parent, ctx, xpath_text(value), false)
        end
      end

      def deep_copy(node, parent, ctx)
        if node.element?
          element = ctx.result.create_element(node.name)
          append_node(parent, element)
          copy_namespaces(node, element)
          node.attribute_nodes.each { |attr| copy_attribute(attr, element) }
          node.pure.children.each { |child| deep_copy(child, element, ctx) }
        elsif node.text? || node.cdata?
          append_text(parent, ctx, node.pure.content.to_s, false)
        elsif node.comment?
          append_node(parent, ctx.result.create_comment(node.pure.content.to_s))
        end
      end

      def append_text(parent, ctx, text, raw)
        node = ctx.result.create_text_node(text.to_s)
        node.instance_variable_set(:@xslt_disable_output_escaping, true) if raw
        append_node(parent, node)
      end

      def append_node(parent, node)
        if parent.document?
          parent.add_child_node(node)
        else
          parent.add_child(node)
        end
      end

      def test_true?(expression, ctx)
        value = evaluate(ctx.node, expression, ctx.variables)
        case value
        when XML::NodeSet then !value.empty?
        when Numeric then number = value.to_f
                          !number.zero? && !number.nan?
        when String then !value.empty?
        when true then true
        when false then false
        else !value.nil?
        end
      end

      def node_set(node, expression, variables)
        value = evaluate(node, expression, variables)
        value.is_a?(XML::NodeSet) ? value.to_a : []
      end

      def string_value(node, expression, variables)
        return "" if expression.nil? || expression.empty?

        value = evaluate(node, expression, variables)
        case value
        when XML::NodeSet
          value.empty? ? "" : value.first.content.to_s
        else
          xpath_text(value)
        end
      end

      def xpath_text(value)
        case value
        when Float
          (value.finite? && value == value.to_i) ? value.to_i.to_s : value.to_s
        when true then "true"
        when false then "false"
        when nil then ""
        else
          value.to_s
        end
      end

      def evaluate(node, expression, variables)
        previous = @xpath_context
        @xpath_context = node
        xpath = XML::XPathContext.new(node)
        @namespaces.each { |prefix, href| xpath.register_ns(prefix, href) }
        variables.each { |name, value| xpath.register_variable(name, value) }
        xpath.evaluate(expression, @caller)
      rescue XML::XPath::SyntaxError => error
        raise error.message.to_s
      ensure
        @xpath_context = previous
      end

      def apply_strip_space(document)
        @strip_restores = []
        return if @strip_names.empty?

        strip_walk(document)
      end

      def strip_walk(node)
        state = node.instance_variable_get(:@pure)
        return unless state

        if strip_element?(node)
          state.children.each do |child|
            next unless whitespace_text?(child)

            original = child.pure.content.to_s
            next if original.empty?

            @strip_restores << [child, original] if child.instance_variable_get(:@xslt_observed)
            child.pure.content = ""
          end
        end
        state.children.each { |child| strip_walk(child) }
      end

      def restore_strip_space
        return if @strip_restores.nil?

        @strip_restores.each { |node, original| node.pure.content = original }
        @strip_restores = nil
      end

      def strip_element?(node)
        return false unless node.element?

        @strip_names.any? { |token| token == "*" || token == node.name }
      end

      def whitespace_text?(node)
        return false unless node.text? || node.cdata?

        node.pure.content.to_s.match?(/\A[ \t\r\n]*\z/)
      end

      def namespace_used?(href)
        @namespaces.value?(href)
      end

      def handler_class_for(name)
        symbol = name.to_sym
        @namespaces.each_value do |href|
          klass = XSLT.handlers[href]
          next unless klass.respond_to?(:instance_methods)
          return klass if klass.method_defined?(symbol, false)
        end
        nil
      end

      def handler_instance(klass)
        @instances[klass] ||= klass.is_a?(Class) ? klass.new : klass
      end

      def exslt_max(arg)
        values = if arg.is_a?(XML::NodeSet)
          arg.map { |node| xpath_number(node.content) }
        else
          [xpath_number(arg)]
        end
        return Float::NAN if values.empty?

        values.max
      end

      def xpath_number(value)
        Float(value.to_s)
      rescue ArgumentError, TypeError
        Float::NAN
      end

      def attribute_node?(node)
        node.node_type == XML::Node::ATTRIBUTE_NODE
      end

      def function_element?(node)
        node.namespace&.href == FUNC_NS && node.name == "function"
      end

      def html_output?(document)
        case @output_method
        when "html" then true
        when "xml", "text" then false
        else html_heuristic?(document)
        end
      end

      def html_heuristic?(document)
        document.pure.children.each do |child|
          next if child.text? && child.blank?

          return false unless child.element?

          return child.namespace.nil? && child.name.match?(/\Ahtml\z/i)
        end
        false
      end

      def xsl?(node)
        node&.element? && node.namespace&.href == XSLT_NS
      end
    end
  end

  module XSLT
    class Stylesheet
      def self.parse_stylesheet_doc(document)
        sheet = allocate
        sheet.instance_variable_set(:@engine, Pure::XsltEngine.compile(document))
        sheet
      end

      def transform(document, params = [])
        unless document.is_a?(XML::Document)
          raise ArgumentError, "argument must be a Nokogiri::XML::Document"
        end

        params = [] if params.nil?
        if params.is_a?(Hash)
          params = params.to_a.flatten
        end
        unless params.is_a?(Array)
          raise TypeError, "wrong argument type #{params.class} (expected Array)"
        end

        @engine.transform(document, params)
      end

      def serialize(document)
        @engine.serialize(document)
      end
    end
  end
end
