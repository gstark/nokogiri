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
    end
  end
end
