# frozen_string_literal: true

module Nokogiri
  module XML
    class Node
      # xml/node.rb loads after pure/dom.rb and would replace an earlier
      # definition. Element content= escapes, then native_content= decodes.
      # Those two scans are an identity, so store the input text directly.
      def content=(string)
        text = string.to_s
        if element?
          replace_element_text(text)
        else
          self.native_content = encode_special_chars(text)
        end
        string
      end

      # xml/node.rb loads after pure/dom.rb. Build the hash from the attribute
      # list. The NodeSet wrapper is only needed for #attribute_nodes.
      def attributes
        list = pure.attributes
        hash = {}
        doc = document
        decorators = doc&.instance_variable_get(:@decorators)
        index = 0
        length = list.length
        while index < length
          attr = list[index]
          doc.decorate(attr) if decorators
          hash[attr.node_name] = attr
          index += 1
        end
        hash
      end
    end
  end
end
