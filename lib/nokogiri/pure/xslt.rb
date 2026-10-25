# frozen_string_literal: true

module Nokogiri
  module Pure
    # XSLT 1.0 subset used by the pure backend.
    #
    # Covers xsl:output, xsl:param, xsl:template match="/", literal result
    # elements, xsl:value-of, and xsl:for-each. Extension functions are not loaded.
    class XsltEngine
      XSLT_NS = "http://www.w3.org/1999/XSL/Transform"
      TOP_LEVEL = %w[
        import include strip-space preserve-space output key decimal-format
        attribute-set variable param template namespace-alias
      ].freeze

      Context = Struct.new(:node, :variables, :result)

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
      end

      def compile(document)
        root = document.root
        unless xsl?(root) && %w[stylesheet transform].include?(root.name)
          raise RuntimeError, "invalid stylesheet"
        end

        root.namespace_scopes.each do |ns|
          @namespaces[ns.prefix] = ns.href if ns.prefix && !ns.prefix.empty?
        end

        root.pure.children.each do |child|
          next unless child.element?
          unless xsl?(child) && TOP_LEVEL.include?(child.name)
            raise RuntimeError, "element #{child.name} is not allowed in an XSLT stylesheet"
          end

          compile_top(child)
        end
        self
      end

      def transform(document, params)
        variables = {}
        @params.each do |name, expression|
          variables[name] = expression ? string_value(document, expression, variables) : ""
        end
        params.each_slice(2) do |name, expression|
          variables[name.to_s] = string_value(document, expression.to_s, variables)
        end

        result = XML::Document.new(@output_version || "1.0")
        result.encoding = @output_encoding if @output_encoding
        template = @templates.reverse.find { |item| item[:match] == "/" }
        if template
          execute(template[:body], Context.new(document, variables, result), result)
        end
        result.pure.type = XML::Node::HTML_DOCUMENT_NODE if html_output?(result)
        result
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
          @templates << { match: node["match"].to_s, body: compile_sequence(node) }
        end
      end

      def compile_sequence(node)
        node.pure.children.filter_map { |child| compile_instruction(child) }
      end

      def compile_instruction(node)
        if node.text?
          return if node.blank?

          return [:text, node.content]
        end
        return unless node.element?
        return compile_xsl(node) if xsl?(node)

        attributes = node.pure.attributes.map { |attr| [attr.name, attr.content.to_s] }
        [:element, node.name, attributes, compile_sequence(node)]
      end

      def compile_xsl(node)
        case node.name
        when "value-of"
          [:value_of, node["select"].to_s]
        when "for-each"
          [:for_each, node["select"].to_s, compile_sequence(node)]
        when "text"
          [:text, node.content.to_s]
        end
      end

      def execute(instructions, ctx, parent)
        instructions.each do |instruction|
          case instruction[0]
          when :text
            parent.add_child(ctx.result.create_text_node(instruction[1]))
          when :element
            element = ctx.result.create_element(instruction[1])
            instruction[2].each { |name, value| element[name] = value }
            parent.add_child(element)
            execute(instruction[3], ctx, element)
          when :value_of
            parent.add_child(ctx.result.create_text_node(string_value(ctx.node, instruction[1], ctx.variables)))
          when :for_each
            node_set(ctx.node, instruction[1], ctx.variables).each do |node|
              execute(instruction[2], Context.new(node, ctx.variables, ctx.result), parent)
            end
          end
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
        when Float
          number = value
          number.finite? && number == number.to_i ? number.to_i.to_s : number.to_s
        when true then "true"
        when false then "false"
        else
          value.to_s
        end
      end

      def evaluate(node, expression, variables)
        xpath = XML::XPathContext.new(node)
        @namespaces.each { |prefix, href| xpath.register_ns(prefix, href) }
        variables.each { |name, value| xpath.register_variable(name, value) }
        xpath.evaluate(expression)
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
