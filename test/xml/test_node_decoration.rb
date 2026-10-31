# frozen_string_literal: true

require "helper"

module Nokogiri
  module XML
    # A node gets the document's decorators when Ruby first sees it, also when Ruby creates it.
    # Loofah depends on this: it adds +scrub!+ to the fragments it creates.
    class TestNodeDecoration < Nokogiri::TestCase
      DECORATOR = Module.new do
        def decorated?
          true
        end
      end

      # The Loofah pattern: the document class adds its decorators on initialize.
      def self.decorated_class(base)
        Class.new(base) do
          def initialize(*args)
            super
            decorators(Nokogiri::XML::Node) << DECORATOR
            decorators(Nokogiri::XML::NodeSet) << DECORATOR
          end
        end
      end

      XML_DOCUMENT = decorated_class(Nokogiri::XML::Document)
      HTML4_DOCUMENT = decorated_class(Nokogiri::HTML4::Document)

      def assert_decorated(object)
        assert_respond_to(object, :decorated?, "expected #{object.class} to be decorated")
      end

      def test_new_element
        assert_decorated(Nokogiri::XML::Element.new("a", XML_DOCUMENT.new))
      end

      def test_new_text
        assert_decorated(Nokogiri::XML::Text.new("a", XML_DOCUMENT.new))
      end

      def test_new_comment
        assert_decorated(Nokogiri::XML::Comment.new(XML_DOCUMENT.new, "a"))
      end

      def test_new_cdata
        assert_decorated(Nokogiri::XML::CDATA.new(XML_DOCUMENT.new, "a"))
      end

      def test_new_processing_instruction
        assert_decorated(Nokogiri::XML::ProcessingInstruction.new(XML_DOCUMENT.new, "a", "b"))
      end

      def test_new_attr
        assert_decorated(Nokogiri::XML::Attr.new(XML_DOCUMENT.new, "a"))
      end

      def test_document_create_methods
        doc = XML_DOCUMENT.new

        assert_decorated(doc.create_element("a"))
        assert_decorated(doc.create_text_node("a"))
        assert_decorated(doc.create_comment("a"))
        assert_decorated(doc.create_cdata("a"))
      end

      def test_new_xml_fragment
        fragment = Nokogiri::XML::DocumentFragment.new(XML_DOCUMENT.new, "<a>b</a>")

        assert_decorated(fragment)
        assert_decorated(fragment.children)
        assert_decorated(fragment.children.first)
      end

      def test_xml_document_fragment_method
        fragment = XML_DOCUMENT.new.fragment("<a>b</a>")

        assert_decorated(fragment)
        assert_decorated(fragment.children.first)
      end

      def test_new_html4_fragment
        fragment = Nokogiri::HTML4::DocumentFragment.new(HTML4_DOCUMENT.new, "<b>a</b>")

        assert_decorated(fragment)
        assert_decorated(fragment.children.first)
      end

      def test_new_html5_fragment
        skip("HTML5 is not supported") unless Nokogiri.uses_gumbo?

        document = self.class.decorated_class(Nokogiri::HTML5::Document).new
        fragment = Nokogiri::HTML5::DocumentFragment.new(document, "<b>a</b>")

        assert_decorated(fragment)
        assert_decorated(fragment.children.first)
      end
    end
  end
end
