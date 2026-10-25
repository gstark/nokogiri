# frozen_string_literal: true

module Nokogiri
  module HTML4
    class ElementDescription
      def self.[](tag_name)
        desc = DefaultDescriptions[tag_name.to_s.downcase]
        return unless desc

        allocate.tap { |description| description.instance_variable_set(:@name, desc.name) }
      end

      def name
        @name
      end

      def empty?
        !!default_desc&.empty
      end

      def inline?
        !!default_desc&.isinline
      end

      def sub_elements
        default_desc&.subelts || []
      end

      ###
      # Is this element a block element?
      def block?
        !inline?
      end

      ###
      # Convert this description to a string
      def to_s
        "#{name}: #{description}"
      end

      ###
      # Inspection information
      def inspect
        "#<#{self.class.name}: #{name} #{description}>"
      end
    end
  end
end
