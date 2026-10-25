# frozen_string_literal: true

module Nokogiri
  module Pure
    # RELAX NG subset used by the pure backend.
    #
    # Covers element, group, choice, oneOrMore, zeroOrMore, optional, and text.
    # Remote schema documents are not loaded.
    class RelaxNGModel
      def self.compile(document)
        new(document.root)
      end

      def initialize(root)
        @pattern = compile_node(root)
      end

      def validate(document)
        nodes = document.root ? [document.root] : []
        return [schema_error("Document is empty")] if nodes.empty?
        return [] if matches?(@pattern, nodes) && nodes.empty?

        [schema_error("RELAX NG validity error")]
      end

      private

      def compile_node(node)
        return [:empty] unless node&.element?

        case node.name
        when "element"
          [:element, node["name"].to_s, compile_children(node)]
        when "oneOrMore"
          [:one_or_more, compile_children(node)]
        when "zeroOrMore"
          [:zero_or_more, compile_children(node)]
        when "optional"
          [:optional, compile_children(node)]
        when "choice"
          [:choice, compile_parts(node)]
        when "group", "interleave"
          [:group, compile_parts(node)]
        when "text", "empty", "data", "value"
          [node.name.to_sym]
        else
          compile_children(node)
        end
      end

      def compile_children(node)
        parts = compile_parts(node)
        case parts.length
        when 0 then [:empty]
        when 1 then parts[0]
        else [:group, parts]
        end
      end

      def compile_parts(node)
        node.element_children.map { |child| compile_node(child) }
      end

      def matches?(pattern, nodes)
        saved = nodes.dup
        ok = consume(pattern, nodes)
        nodes.replace(saved) unless ok
        ok
      end

      def consume(pattern, nodes)
        kind, body, extra = pattern
        case kind
        when :element
          node = nodes.first
          return false unless node&.element? && node.name == body && node.namespace.nil?

          children = node.pure.children.select(&:element?)
          return false unless matches?(extra, children) && children.empty?

          nodes.shift
          true
        when :group
          body.all? { |part| matches?(part, nodes) }
        when :choice
          body.any? { |part| matches?(part, nodes) }
        when :one_or_more
          return false unless matches?(body, nodes)

          nil while matches?(body, nodes)
          true
        when :zero_or_more
          nil while matches?(body, nodes)
          true
        when :optional
          matches?(body, nodes)
          true
        when :text, :empty, :data, :value
          true
        else
          false
        end
      end

      def schema_error(message)
        XML::SyntaxError.new(message)
      end
    end
  end

  module XML
    class RelaxNG
      def self.from_document(document, parse_options_ = ParseOptions::DEFAULT_SCHEMA, parse_options: parse_options_)
        unless document.is_a?(XML::Node)
          raise TypeError, "wrong argument type #{document.class} (expected Nokogiri::XML::Node)"
        end
        unless document.is_a?(XML::Document)
          warn("Passing a Node as the first parameter to Schema.from_document is deprecated. Please pass a Document instead. This will become an error in Nokogiri v1.17.0.")
          document = document.document
        end
        if document.errors.any?(&:fatal?)
          exception = SyntaxError.aggregate(document.errors.select(&:fatal?))
          raise exception if exception
        end

        schema = allocate
        schema.errors = []
        schema.parse_options = parse_options.is_a?(ParseOptions) ? parse_options : ParseOptions.new(parse_options)
        schema.instance_variable_set(:@model, Pure::RelaxNGModel.compile(document))
        schema
      end
    end
  end
end
