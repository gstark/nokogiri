# frozen_string_literal: true

module Nokogiri
  module XML
    class EntityDecl < Nokogiri::XML::Node
      INTERNAL_GENERAL = 1
      EXTERNAL_GENERAL_PARSED = 2
      EXTERNAL_GENERAL_UNPARSED = 3
      INTERNAL_PARAMETER = 4
      EXTERNAL_PARAMETER = 5
      INTERNAL_PREDEFINED = 6

      undef_method :attribute_nodes
      undef_method :attributes
      undef_method :namespace
      undef_method :namespace_definitions
      undef_method :line if method_defined?(:line)

      def self.new(name, doc, *args)
        doc.create_entity(name, *args)
      end

      def entity_type
        @entity_type || INTERNAL_GENERAL
      end

      def external_id
        pure.external_id
      end

      def system_id
        pure.system_id
      end

      def content
        pure.content.to_s
      end

      alias_method :original_content, :content

      def to_s
        body = if entity_type == INTERNAL_GENERAL
          %("#{content}")
        elsif external_id
          %(PUBLIC "#{external_id}" "#{system_id}")
        else
          %(SYSTEM "#{system_id}")
        end
        "<!ENTITY #{name} #{body}>\n"
      end

      private

      def inspect_attributes
        [:to_s]
      end
    end
  end
end
