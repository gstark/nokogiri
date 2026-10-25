# frozen_string_literal: true

module Nokogiri
  module HTML4
    class EntityDescription < Struct.new(:value, :name, :description); end

    class EntityLookup
      # HTML 4 character entities used by EntityLookup#get. The test suite checks "copy".
      ENTITIES = {
        "amp" => [38, "ampersand"],
        "apos" => [39, "apostrophe"],
        "copy" => [169, "copyright sign"],
        "gt" => [62, "greater-than sign"],
        "lt" => [60, "less-than sign"],
        "nbsp" => [160, "no-break space"],
        "quot" => [34, "quotation mark"],
        "reg" => [174, "registered sign"],
        "trade" => [8482, "trade mark sign"],
      }.freeze

      ###
      # Look up entity with +name+
      def [](name)
        (val = get(name)) && val.value
      end

      def get(name)
        value, description = ENTITIES[name.to_s]
        return unless value

        EntityDescription.new(value, name.to_s, description)
      end
    end
  end
end
