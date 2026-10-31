# frozen_string_literal: true

require "helper"

module Nokogiri
  module HTML
    # Tree construction rules of the libxml2 HTML4 parser before v2.14.
    # Loofah and other sanitizers depend on these trees.
    class TestTreeConstruction < Nokogiri::TestCase
      def setup
        super
        return if Nokogiri.uses_libxml?("< 2.14.0")
        return if defined?(Nokogiri::PURE_RUBY) && Nokogiri::PURE_RUBY

        skip("these tests check the libxml2 HTML4 parser before v2.14")
      end

      def names(node)
        node.children.map(&:name)
      end

      describe "script and style content" do
        def test_script_content_is_one_cdata_node
          script = Nokogiri::HTML4("<div><script>a</b><c>&amp;</script></div>").at_css("script")

          assert_equal(["#cdata-section"], names(script))
          assert_equal("a</b><c>&amp;", script.content)
        end

        def test_script_start_tag_inside_script_is_text
          script = Nokogiri::HTML4(%(<script><script src="x">this & that</script>)).at_css("script")

          assert_equal(["#cdata-section"], names(script))
          assert_equal(%(<script src="x">this & that), script.content)
        end

        def test_style_content_is_one_cdata_node
          style = Nokogiri::HTML4("<style>a <b> c</style><p>x</p>").at_css("style")

          assert_equal(["#cdata-section"], names(style))
          assert_equal("a <b> c", style.content)
        end

        def test_fragment_script_content_is_one_cdata_node
          script = Nokogiri::HTML4::DocumentFragment.parse("<script><script>alert(1)</script></script>").at_css("script")

          assert_equal(["#cdata-section"], names(script))
          assert_equal("<script>alert(1)", script.content)
        end

        def test_script_content_after_processing_instruction
          script = Nokogiri::HTML4("<?pi x?><script>a</b>c</SCRIPT>").at_css("script")

          assert_equal(["#cdata-section"], names(script))
          assert_equal("a</b>c", script.content)
        end

        def test_script_content_serializes_raw_as_html
          script = Nokogiri::HTML4("<div><script>a<b</script></div>").at_css("script")

          assert_equal("<script>a<b</script>", script.to_html)
          assert_equal("<script><![CDATA[a<b]]></script>", script.to_xml)
        end
      end
    end
  end
end
