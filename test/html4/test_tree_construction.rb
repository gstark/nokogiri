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

      # A leading processing instruction sends the pure parser down its
      # general path. Both paths must give the same tree.
      PATH_PREFIXES = ["", "<?pi x?>"].freeze

      def messages(doc)
        doc.errors.map { |error| error.message.strip.sub(/\A\d+:\d+: [A-Z]+: /, "") }
      end

      describe "start tag attributes" do
        def test_slash_skips_to_the_next_attribute
          PATH_PREFIXES.each do |prefix|
            script = Nokogiri::HTML4("#{prefix}<script/XSS src='u'></script>").at_css("script")

            assert_equal({"src" => "u"}, script.to_h)
            assert_empty(script.children)
          end
        end

        def test_slash_before_the_only_attribute_drops_it
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4(%(#{prefix}<a/href="u">x</a><img/src='u'/>))

            assert_empty(doc.at_css("a").to_h)
            assert_equal("x", doc.at_css("a").content)
            assert_empty(doc.at_css("img").to_h)
          end
        end

        def test_unquoted_value_keeps_a_slash
          PATH_PREFIXES.each do |prefix|
            a = Nokogiri::HTML4("#{prefix}<a href=x/ y=1>t</a>").at_css("a")

            assert_equal({"href" => "x/", "y" => "1"}, a.to_h)
          end
        end

        def test_bad_attribute_name_is_skipped_with_an_error
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4("#{prefix}<a =x b=1>t</a>")

            assert_equal({"b" => "1"}, doc.at_css("a").to_h)
            assert_equal(["error parsing attribute name"], messages(doc).grep(/attribute name/))
          end
        end

        def test_first_duplicate_attribute_stays
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4("#{prefix}<a X=1 x=2 y y>t</a>")

            assert_equal({"x" => "1", "y" => ""}, doc.at_css("a").to_h)
            assert_equal(["Attribute x redefined", "Attribute y redefined"], messages(doc).grep(/redefined/))
          end
        end

        def test_attributes_need_no_space_between_them
          PATH_PREFIXES.each do |prefix|
            a = Nokogiri::HTML4(%(#{prefix}<a b="1"c=2>t</a>)).at_css("a")

            assert_equal({"b" => "1", "c" => "2"}, a.to_h)
          end
        end

        def test_unclosed_quote_runs_to_the_end_of_the_input
          doc = Nokogiri::HTML4("<div><a x='abc>t</a>")

          assert_equal("abc>t</a>", doc.at_css("a")["x"])
          assert_empty(doc.at_css("a").children)
          assert_includes(messages(doc), "AttValue: ' expected")
          assert_includes(messages(doc), "Couldn't find end of Start Tag a")
        end
      end

      describe "character and entity references" do
        def test_numeric_reference_without_semicolon_is_decoded
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4(%(#{prefix}<a href="data:&#58text">x</a>))

            assert_equal("data::text", doc.at_css("a")["href"])
            assert_includes(messages(doc), "htmlParseCharRef: missing semicolon")
          end
        end

        def test_html4_named_entities_are_decoded
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4("#{prefix}<p title='&eacute;&copy;'>&nbsp;&eacute;&copy;</p>")

            assert_equal(" é©", doc.at_css("p").content)
            assert_equal("é©", doc.at_css("p")["title"])
          end
        end

        def test_named_reference_without_semicolon_stays_as_text
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4("#{prefix}<p title='&copy x'>&copy x &foo; &amp</p>")
            p = doc.at_css("p")

            assert_equal(["text"], names(p))
            assert_equal("&copy x &foo; &amp", p.content)
            assert_equal("&copy x", p["title"])
            assert_equal(3, messages(doc).count("htmlParseEntityRef: expecting ';'"))
          end
        end

        def test_reference_to_an_invalid_character
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4("#{prefix}<p title='a&#0;b'>a&#0;b</p>")

            assert_equal("ab", doc.at_css("p").content)
            assert_equal("a", doc.at_css("p")["title"])
            assert_includes(messages(doc), "htmlParseCharRef: invalid xmlChar value 0")
          end
        end

        def test_reference_error_location
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4("#{prefix}<p>line1\n&copy x</p>")
            error = doc.errors.find { |e| e.message.include?("expecting ';'") }

            assert_equal([2, 6], [error.line, error.column])
          end
        end
      end
    end
  end
end
