# frozen_string_literal: true

module Nokogiri
  module XML
    class ElementDecl < Nokogiri::XML::Node
      undef_method :namespace
      undef_method :namespace_definitions
      undef_method :line if method_defined?(:line)

      def element_type
        @element_type
      end

      def content
        @element_content
      end

      def to_s
        "<!ELEMENT #{name} #{@content_model}>\n"
      end

      def prefix
        name.include?(":") ? name.split(":", 2).first : nil
      end

      private

      def inspect_attributes
        [:to_s]
      end
    end
  end
end
