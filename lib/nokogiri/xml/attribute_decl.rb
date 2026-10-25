# frozen_string_literal: true

module Nokogiri
  module XML
    ###
    # Represents an attribute declaration in a DTD
    class AttributeDecl < Nokogiri::XML::Node
      undef_method :attribute_nodes
      undef_method :attributes
      undef_method :content
      undef_method :namespace
      undef_method :namespace_definitions
      undef_method :line if method_defined?(:line)

      def attribute_type
        @attribute_type
      end

      def default
        @default_value
      end

      def enumeration
        @enumeration || []
      end

      def to_s
        kind = enumeration.empty? ? @attribute_type : "(#{enumeration.join("|")})"
        fallback = @default_value.nil? ? "#IMPLIED" : %("#{@default_value}")
        "<!ATTLIST #{@owner_element} #{name} #{kind} #{fallback}>\n"
      end

      private

      def inspect_attributes
        [:to_s]
      end
    end
  end
end
