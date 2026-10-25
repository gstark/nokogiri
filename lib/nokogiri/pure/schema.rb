# frozen_string_literal: true

module Nokogiri
  module Pure
    # XSD subset used by the pure backend.
    #
    # Covers named types, sequences, element references, attributes, and the
    # simple types the schema tests validate. Remote schema documents are not loaded.
    class SchemaModel
      XS = "http://www.w3.org/2001/XMLSchema"

      ElementRule = Struct.new(
        :name, :ref, :namespace, :type_name, :inline, :min, :max,
        keyword_init: true,
      )
      ComplexRule = Struct.new(:particle, :attributes, keyword_init: true)
      SimpleRule = Struct.new(
        :base, :pattern, :max_exclusive, :min_inclusive, :enumerations,
        keyword_init: true,
      )
      AttributeRule = Struct.new(:name, :type_name, :use, :fixed, keyword_init: true)
      GroupRule = Struct.new(:particle, keyword_init: true)

      def self.compile(document)
        new.compile(document)
      end

      def initialize
        @elements = {}
        @complex = {}
        @simple = {}
        @groups = {}
        @loaded = {}
        @target_namespace = nil
      end

      def compile(document)
        read_schema(document.root, document.url)
        self
      end

      def validate(document)
        root = document.respond_to?(:root) ? document.root : nil
        return [schema_error("Document is empty")] unless root

        rule = global_element(root)
        return [schema_error("Element '#{root.name}': No matching global declaration available")] unless rule

        errors = []
        check_element(root, rule, errors)
        errors
      end

      private

      def read_schema(root, base_url)
        return unless root && xs?(root) && root.name == "schema"

        @target_namespace = root["targetNamespace"]
        root.element_children.each { |child| read_top(child, base_url, @target_namespace) }
      end

      def read_top(node, base_url, target_namespace)
        return unless xs?(node)

        case node.name
        when "element"
          rule = compile_element(node, target_namespace)
          @elements[rule.name] = rule if rule.name
        when "complexType"
          @complex[node["name"]] = compile_complex(node, target_namespace) if node["name"]
        when "simpleType"
          @simple[node["name"]] = compile_simple(node) if node["name"]
        when "group"
          @groups[node["name"]] = compile_group(node, target_namespace) if node["name"]
        when "include", "import", "redefine"
          load_related(node, base_url)
        end
      end

      def load_related(node, base_url)
        path = local_path(node["schemaLocation"], base_url)
        return unless path
        return if @loaded[path]

        @loaded[path] = true
        related = XML::Document.parse(File.read(path), path)
        saved = @target_namespace
        read_schema(related.root, path)
        @target_namespace = saved
      rescue XML::SyntaxError
        nil
      end

      def local_path(location, base_url)
        return if location.nil? || location.empty?
        return if location.match?(%r{\A[a-z][a-z0-9+.-]*://}i)

        if base_url && !base_url.empty? && !base_url.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
          candidate = File.expand_path(location, File.dirname(base_url))
          return candidate if File.file?(candidate)
        end
        return location if File.file?(location)

        nil
      end

      def compile_element(node, target_namespace)
        ElementRule.new(
          name: node["name"],
          ref: node["ref"]&.split(":", 2)&.last,
          namespace: node["name"] ? target_namespace : nil,
          type_name: local_name(node["type"]),
          inline: inline_type(node, target_namespace),
          min: integer_attr(node, "minOccurs", 1),
          max: node["maxOccurs"] == "unbounded" ? nil : integer_attr(node, "maxOccurs", 1),
        )
      end

      def inline_type(node, target_namespace)
        node.element_children.each do |child|
          next unless xs?(child)

          return compile_complex(child, target_namespace) if child.name == "complexType"
          return compile_simple(child) if child.name == "simpleType"
        end
        nil
      end

      def compile_complex(node, target_namespace)
        particle = nil
        attributes = []
        node.element_children.each do |child|
          next unless xs?(child)

          case child.name
          when "sequence", "choice", "all"
            particle = compile_compositor(child, target_namespace)
          when "attribute"
            attributes << compile_attribute(child)
          when "complexContent", "simpleContent"
            base = content_base(child, target_namespace)
            particle = base.particle if base
            attributes = base.attributes + attributes if base
          end
        end
        ComplexRule.new(particle: particle, attributes: attributes)
      end

      def content_base(node, target_namespace)
        extension = node.element_children.find { |child| xs?(child) && %w[extension restriction].include?(child.name) }
        return unless extension

        base = resolve_complex(local_name(extension["base"]))
        extra = extension.element_children.find { |child| xs?(child) && %w[sequence choice all].include?(child.name) }
        return base unless extra

        particle = compile_compositor(extra, target_namespace)
        ComplexRule.new(
          particle: compositor("sequence", [base&.particle, particle].compact),
          attributes: base&.attributes || [],
        )
      end

      def compile_group(node, target_namespace)
        child = node.element_children.find { |item| xs?(item) && %w[sequence choice all].include?(item.name) }
        GroupRule.new(particle: child && compile_compositor(child, target_namespace))
      end

      def compile_compositor(node, target_namespace)
        particles = node.element_children.filter_map { |child| compile_particle(child, target_namespace) }
        compositor(node.name, particles)
      end

      def compositor(kind, particles)
        ElementRule.new(
          name: kind,
          ref: nil,
          namespace: nil,
          type_name: kind,
          inline: particles,
          min: 1,
          max: 1,
        )
      end

      def compile_particle(node, target_namespace)
        return unless xs?(node)

        case node.name
        when "element"
          compile_element(node, nil)
        when "sequence", "choice", "all"
          compile_compositor(node, target_namespace)
        when "group"
          name = local_name(node["ref"])
          ElementRule.new(
            name: name,
            ref: name,
            type_name: "group",
            min: integer_attr(node, "minOccurs", 1),
            max: node["maxOccurs"] == "unbounded" ? nil : integer_attr(node, "maxOccurs", 1),
          )
        end
      end

      def compile_attribute(node)
        AttributeRule.new(
          name: local_name(node["name"] || node["ref"]),
          type_name: local_name(node["type"]),
          use: node["use"] || "optional",
          fixed: node["fixed"],
        )
      end

      def compile_simple(node)
        restriction = node.element_children.find { |child| xs?(child) && child.name == "restriction" }
        return SimpleRule.new(base: "string") unless restriction

        pattern = nil
        max_exclusive = nil
        min_inclusive = nil
        enumerations = []
        restriction.element_children.each do |child|
          next unless xs?(child)

          case child.name
          when "pattern" then pattern = child["value"]
          when "maxExclusive" then max_exclusive = child["value"]
          when "minInclusive" then min_inclusive = child["value"]
          when "enumeration" then enumerations << child["value"]
          end
        end
        SimpleRule.new(
          base: local_name(restriction["base"]) || "string",
          pattern: pattern,
          max_exclusive: max_exclusive,
          min_inclusive: min_inclusive,
          enumerations: enumerations,
        )
      end

      def global_element(element)
        rule = @elements[element.name]
        return unless rule
        return unless rule.namespace.to_s == element.namespace&.href.to_s

        rule
      end

      def check_element(element, rule, errors)
        type = rule.inline || resolve_type(rule.type_name)
        case type
        when ComplexRule
          check_complex(element, type, errors)
        when SimpleRule
          check_value(element.text, type, errors, element.name)
          element.element_children.each do |child|
            errors << schema_error("Element '#{child.name}': This element is not expected.")
          end
        end
      end

      def check_complex(element, type, errors)
        check_particle(element, type.particle, errors) if type.particle
        type.attributes.each do |attribute|
          value = element[attribute.name]
          if attribute.use == "required" && value.nil?
            errors << schema_error("Element '#{element.name}': The attribute '#{attribute.name}' is required")
            next
          end
          next if value.nil?

          if attribute.fixed && value != attribute.fixed
            errors << schema_error("Element '#{element.name}', attribute '#{attribute.name}': '#{value}' is not equal to the fixed value")
          end
          simple = resolve_simple(attribute.type_name)
          check_value(value, simple, errors, "#{element.name}/@#{attribute.name}") if simple
        end
      end

      def check_particle(element, particle, errors)
        return unless particle

        if particle.type_name == "sequence" || particle.type_name == "all"
          check_sequence(element, particle.inline || [], errors)
        elsif particle.type_name == "choice"
          check_choice(element, particle.inline || [], errors)
        elsif particle.type_name == "group"
          group = @groups[particle.ref]
          check_particle(element, group.particle, errors) if group&.particle
        else
          # A single element particle is not used at the complex-type root.
        end
      end

      def check_sequence(element, particles, errors)
        children = element.element_children
        index = 0
        particles.each do |particle|
          if particle.type_name == "sequence" || particle.type_name == "choice" || particle.type_name == "group"
            check_particle(element, particle, errors)
            next
          end

          count = 0
          while index < children.length && (particle.max.nil? || count < particle.max) && element_match?(children[index], particle)
            check_matched(children[index], particle, errors)
            index += 1
            count += 1
          end
          if count < particle.min
            errors << schema_error("Element '#{particle.name || particle.ref}': This element is not expected. Expected is ( #{particle.name || particle.ref} ).")
          end
        end
        while index < children.length
          errors << schema_error("Element '#{children[index].name}': This element is not expected.")
          index += 1
        end
      end

      def check_choice(element, particles, errors)
        child = element.element_children.first
        chosen = particles.find { |particle| child && element_match?(child, particle) }
        if chosen
          check_sequence(element, [chosen], errors)
        elsif particles.any? { |particle| particle.min.positive? }
          errors << schema_error("Element '#{element.name}': Missing child element(s).")
        end
      end

      def element_match?(child, particle)
        expected = particle.ref || particle.name
        child.name == expected
      end

      def check_matched(child, particle, errors)
        rule = if particle.ref
          @elements[particle.ref] || particle
        else
          particle
        end
        check_element(child, rule, errors)
      end

      def check_value(text, type, errors, label)
        value = text.to_s.strip
        return if value_ok?(value, type, {})

        errors << schema_error("Element '#{label}': '#{value}' is not a valid value of the atomic type '#{type.base}'")
      end

      def value_ok?(value, type, seen)
        return false unless type
        return false if seen[type.object_id]

        seen[type.object_id] = true
        return false unless base_ok?(value, type.base, seen)
        return false if type.pattern && !pattern_match?(value, type.pattern)
        return false if type.max_exclusive && numeric?(value) && value.to_f >= type.max_exclusive.to_f
        return false if type.min_inclusive && numeric?(value) && value.to_f < type.min_inclusive.to_f
        return false if type.enumerations.any? && !type.enumerations.include?(value)

        true
      end

      def base_ok?(value, base, seen)
        case base
        when nil, "anySimpleType", "string", "normalizedString", "token", "language", "Name", "NCName", "ID", "IDREF", "anyURI", "QName"
          true
        when "NMTOKEN"
          value.match?(/\A[:\w.-]+\z/)
        when "boolean"
          %w[true false 0 1].include?(value)
        when "decimal", "float", "double"
          numeric?(value)
        when "integer", "long", "int", "short", "byte", "nonNegativeInteger", "nonPositiveInteger", "negativeInteger"
          value.match?(/\A[+-]?\d+\z/)
        when "positiveInteger"
          value.match?(/\A\+?[1-9]\d*\z/)
        when "date"
          value.match?(/\A-?\d{4}-\d{2}-\d{2}(Z|[+-]\d{2}:\d{2})?\z/)
        when "dateTime"
          value.match?(/\A-?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        else
          named = @simple[base]
          return true unless named

          value_ok?(value, named, seen)
        end
      end

      def pattern_match?(value, pattern)
        expression = pattern.gsub("\\d", "[0-9]").gsub("\\D", "[^0-9]")
        Regexp.new("\\A(?:#{expression})\\z").match?(value)
      rescue RegexpError
        true
      end

      def numeric?(value)
        value.match?(/\A[+-]?(\d+(\.\d*)?|\.\d+)\z/)
      end

      def resolve_type(name)
        return if name.nil? || name.empty?
        return builtin_simple(name) if builtin?(name)

        @complex[name] || @simple[name]
      end

      def resolve_simple(name)
        return if name.nil? || name.empty?
        return builtin_simple(name) if builtin?(name)

        @simple[name]
      end

      def resolve_complex(name)
        @complex[name]
      end

      def builtin?(name)
        %w[
          string normalizedString token language NMTOKEN Name NCName ID IDREF anyURI QName
          boolean decimal float double integer positiveInteger nonNegativeInteger
          nonPositiveInteger negativeInteger long int short byte date dateTime time
          anySimpleType
        ].include?(name)
      end

      def builtin_simple(name)
        SimpleRule.new(base: name, enumerations: [])
      end

      def schema_error(message)
        XML::SyntaxError.new(message)
      end

      def xs?(node)
        node.namespace&.href == XS
      end

      def local_name(qname)
        return if qname.nil?

        qname.split(":", 2).last
      end

      def integer_attr(node, name, default)
        (node[name] || default).to_i
      end
    end
  end

  module XML
    class Schema
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
        schema.instance_variable_set(:@model, Pure::SchemaModel.compile(document))
        schema
      end

      private

      def validate_document(document)
        @model.validate(document)
      end

      def validate_file(filename)
        contents = File.read(filename)
        document = if contents.empty?
          XML::Document.new
        else
          XML::Document.parse(contents)
        end
        validate_document(document)
      rescue XML::SyntaxError => error
        [error]
      end
    end
  end
end
