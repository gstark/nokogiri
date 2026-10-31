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

      describe "serialization" do
        def fragment_html(html)
          Nokogiri::HTML4::DocumentFragment.parse(html).to_html
        end

        def test_block_siblings_are_on_new_lines
          assert_equal("<p>a</p>\n<p>b</p>", Nokogiri::HTML4("<div><p>a</p><p>b</p></div>").at_css("div").inner_html)
          assert_equal("<ul>\n<li>a</li>\n<li>b</li>\n</ul>", fragment_html("<ul><li>a</li><li>b</li></ul>"))
          assert_equal("<foo><div>a</div>\n<div>b</div></foo><bar></bar>", fragment_html("<foo><div>a</div><div>b</div></foo><bar></bar>"))
        end

        def test_no_new_lines_for_inline_elements_or_p_parents
          assert_equal("<span>a</span><span>b</span>", fragment_html("<span>a</span><span>b</span>"))
          assert_equal("<pre><div>a</div><div>b</div></pre>", fragment_html("<pre><div>a</div><div>b</div></pre>"))
        end

        def test_no_new_line_next_to_text
          assert_equal(%(<table>\n<col title="1">foo</table>), fragment_html("<table><col title='1'>foo</table>"))
          assert_equal("<div>a</div>x<div>b</div>", fragment_html("<div>a</div>x<div>b</div>"))
        end

        def test_document_format
          doc = Nokogiri::HTML4("<html><body><div>a</div><br><hr><p>x</p></body></html>")

          assert_equal(
            "<html><body>\n<div>a</div>\n<br><hr>\n<p>x</p>\n</body></html>",
            doc.to_html.lines.drop(1).join.chomp
          )
        end

        def test_document_without_format
          doc = Nokogiri::HTML4("<html><body><div>a</div><div>b</div></body></html>")
          html = doc.to_html(save_with: Nokogiri::XML::Node::SaveOptions::AS_HTML)

          assert_equal("<html><body><div>a</div><div>b</div></body></html>\n", html.lines.drop(1).join)
        end
      end

      # The tree below the document, without the DTD.
      def tree(node)
        node.children.map do |child|
          case child.node_type
          when XML::Node::ELEMENT_NODE
            attrs = child.attribute_nodes.map { |attr| " #{attr.name}=#{attr.value}" }.join
            "<#{child.name}#{attrs}>#{tree(child)}</#{child.name}>"
          when XML::Node::TEXT_NODE then child.content.inspect
          when XML::Node::CDATA_SECTION_NODE then "CDATA#{child.content.inspect}"
          when XML::Node::COMMENT_NODE then "<!--#{child.content}-->"
          when XML::Node::PI_NODE then "<?#{child.name}?>"
          when XML::Node::DTD_NODE then ""
          end
        end.join
      end

      # Each case maps an input to its tree and its error messages.
      def assert_trees(cases)
        cases.each do |input, (expected_tree, expected_messages)|
          PATH_PREFIXES.each do |prefix|
            doc = Nokogiri::HTML4(prefix + input)
            expected = [(prefix.empty? ? "" : "<?pi?>") + expected_tree, expected_messages]

            assert_equal(expected, [tree(doc), messages(doc)], "input: #{(prefix + input).inspect}")
          end
        end
      end

      describe "implied elements and auto close" do
        def test_text_implies_a_paragraph
          assert_trees(
            "Foo\nBar" => ['<html><body><p>"Foo\nBar"</p></body></html>', []],
            "What's up <strong>doc</strong>?\n" => [%q(<html><body><p>"What's up "<strong>"doc"</strong>"?\n"</p></body></html>), []],
            "a</br>b" => ['<html><body><p>"ab"</p></body></html>', ["Unexpected end tag : br"]],
            "<span>a</span>\n<div>b</div>" => ['<html><body><span>"a"</span>"\n"<div>"b"</div></body></html>', []],
            "<br/>x" => ['<html><body><br></br>"x"</body></html>', []]
          )
        end

        def test_head_elements_imply_a_head
          assert_trees(
            "<style>foo</style><div>bar</div>" => ['<html><head><style>CDATA"foo"</style></head><body><div>"bar"</div></body></html>', []],
            "<title>a</title>\n\n<div>" => ['<html><head><title>"a"</title>"\n\n"</head><body><div></div></body></html>', []],
            "<meta charset=utf-8><body>x" => ['<html><head><meta charset=utf-8></meta></head><body>"x"</body></html>', []],
            "<head></head>text" => ['<html><head></head><body><p>"text"</p></body></html>', []]
          )
        end

        def test_start_tags_close_open_elements
          assert_trees(
            "<p>a<p>b" => ['<html><body><p>"a"</p><p>"b"</p></body></html>', []],
            "<p><div>x</div></p>" => ['<html><body><p></p><div>"x"</div></body></html>', ["Unexpected end tag : p"]],
            "<a href=x>a<a>b" => ['<html><body><a href=x>"a"</a><a>"b"</a></body></html>', []],
            "<form><form>x</form></form>" => ['<html><body><form></form><form>"x"</form></body></html>', ["Unexpected end tag : form"]],
            "<li>a<ul><li>b</ul>c" => ['<html><body><li>"a"<ul><li>"b"</li></ul>"c"</li></body></html>', []],
            "<ul><li>a<li>b</ul>" => ['<html><body><ul><li>"a"</li><li>"b"</li></ul></body></html>', []],
            "<dl><dt>a<dd>b<dt>c</dl>" => ['<html><body><dl><dt>"a"</dt><dd>"b"</dd><dt>"c"</dt></dl></body></html>', []],
            "<h1>a<h2>b" => ['<html><body><h1>"a"<h2>"b"</h2></h1></body></html>', []],
            "<option>a<option>b" => ['<html><body><option>"a"</option><option>"b"</option></body></html>', []],
            "<table><tr><td>a<td>b</table>" => ['<html><body><table><tr><td>"a"</td><td>"b"</td></tr></table></body></html>', []]
          )
        end

        def test_end_tags_close_to_the_match
          assert_trees(
            "<div><p>a</div>b" => ['<html><body><div><p>"a"</p></div>"b"</body></html>', []],
            "<table><td>a</table>x" => ['<html><body><table><td>"a"</td></table>"x"</body></html>', []],
            "<p>x</b>y" => ['<html><body><p>"xy"</p></body></html>', ["Unexpected end tag : b"]],
            "<div></p></div>" => ["<html><body><div></div></body></html>", ["Unexpected end tag : p"]],
            "<b>a<p>b</b>c" => ['<html><body><b>"a"</b><p>"bc"</p></body></html>', ["Unexpected end tag : b"]],
            "<p>a</div>b" => ['<html><body><p>"ab"</p></body></html>', ["Unexpected end tag : div"]],
            "<div/>x" => ['<html><body><div></div>"x"</body></html>', []],
            "<a><a>x</a></a>" => ['<html><body><a></a><a>"x"</a></body></html>', ["Unexpected end tag : a"]]
          )
        end

        def test_white_space_stays_in_open_elements
          assert_trees(
            "<p>Foo</p>\n<p>Bar</p>" => ['<html><body><p>"Foo"</p>"\n"<p>"Bar"</p></body></html>', []],
            "<p>a</p>\n" => ['<html><body><p>"a"</p>"\n"</body></html>', []],
            "<div>a</div>\n\n" => ['<html><body><div>"a"</div>"\n\n"</body></html>', []],
            "  <div>a</div>  " => ['<html><body><div>"a"</div>"  "</body></html>', []],
            "<head><title>x</title></head>\n<body>\n<p>a</p>\n</body>" => ['<html><head><title>"x"</title></head>"\n"<body>"\n"<p>"a"</p>"\n"</body></html>', []],
            "<html> <head> <title>x</title> </head> <body> <p>a</p> </body> </html>" => ['<html>" "<head>" "<title>"x"</title>" "</head>" "<body>" "<p>"a"</p>" "</body>" "</html>', []]
          )
        end

        def test_misplaced_tags_are_discarded
          assert_trees(
            "<html><body><html lang=x><p>a" => ['<html><body><p>"a"</p></body></html>', ["htmlParseStartTag: misplaced <html> tag"]],
            "<body><div><body/>x" => ['<html><body><div></div>"x"</body></html>', ["htmlParseStartTag: misplaced <body> tag"]],
            "<p><head>x" => ['<html><body><p></p>"x"</body></html>', ["htmlParseStartTag: misplaced <head> tag"]]
          )
        end

        def test_document_level_nodes
          assert_trees(
            "" => ["", []],
            "<!-- c -->" => ["<!-- c -->", []],
            "<!DOCTYPE html><!-- c --><p>x" => ['<!-- c --><html><body><p>"x"</p></body></html>', []],
            "<p>a\n<!-- c -->\n<p>b" => ['<html><body><p>"a\n"<!-- c -->"\n"</p><p>"b"</p></body></html>', []]
          )
        end

        def test_content_after_the_root_makes_a_second_root
          assert_trees(
            "<p>a</p></html><p>b</p>" => ['<html><body><p>"a"</p></body></html><html><p>"b"</p></html>', []],
            "<html><body>a</body></html>b" => ['<html><body>"a"</body></html><html><p>"b"</p></html>', []]
          )
        end

        def test_frameset_has_no_body
          assert_trees(
            "<frameset><frame></frameset>" => ["<html><frameset><frame></frame></frameset></html>", []]
          )
        end

        def test_blank_document_is_empty
          doc = Nokogiri::HTML4("  ")

          assert_empty(tree(doc))
          assert_equal(["Document is empty"], messages(doc))
        end
      end

      describe "end tags" do
        def test_end_tag_skips_to_the_next_close_bracket
          assert_trees(
            "<div>x</div y>z" => ['<html><body><div>"x"</div>"z"</body></html>', ["End tag : expected '>'"]]
          )
        end
      end

      describe "NUL bytes" do
        def test_nul_in_text_is_a_space
          nul_error = "Char 0x0 out of allowed range"
          assert_trees(
            "a\u0000b" => ['<html><body><p>"a b"</p></body></html>', [nul_error]],
            "<p>a\u0000b\u0000\u0000c</p>d" => ['<html><body><p>"a b  c"</p>"d"</body></html>', [nul_error, nul_error, nul_error]],
            "<p>x&amp;y\u0000z</p>" => ['<html><body><p>"x&y z"</p></body></html>', [nul_error]],
            "<div> \u0000 </div>" => ['<html><body><div>"   "</div></body></html>', [nul_error]]
          )
        end

        def test_nul_at_the_start_of_content_ends_the_document
          assert_trees(
            "<p>x</p>\u0000<p>y</p>" => ['<html><body><p>"x"</p></body></html>', []],
            "<div>\u0000</div>z" => ["<html><body><div></div></body></html>", []],
            "<p>a&amp;\u0000b</p>c" => ['<html><body><p>"a&"</p></body></html>', []],
            "<p>a<\u0000b</p>c" => ['<html><body><p>"a<"</p></body></html>', []]
          )
        end

        def test_nul_in_a_tag_ends_the_document
          assert_trees(
            "<div a=1\u0000b=2>x</div>y" => ["<html><body><div a=1></div></body></html>", ["Couldn't find end of Start Tag div"]],
            "<div \u0000>x</div>" => ["<html><body><div></div></body></html>", ["Couldn't find end of Start Tag div"]],
            "<b>q<div\u0000x>r</b>" => ['<html><body><b>"q"<div></div></b></body></html>', ["Couldn't find end of Start Tag div"]],
            "<div>x</d\u0000iv>y" => ['<html><body><div>"x"</div></body></html>', ["End tag : expected '>'", "Unexpected end tag : d"]],
            "<div title='a\u0000b'>x</div>" => ["<html><body><div title=a></div></body></html>", ["AttValue: ' expected", "Couldn't find end of Start Tag div"]],
            "<br\u0000>x" => ["<html><body><br></br></body></html>", ["Couldn't find end of Start Tag br"]]
          )
        end

        def test_fragment_drops_a_tag_broken_up_by_nul
          fragment = Nokogiri::HTML4::DocumentFragment.parse("<scr\u0000ipt>alert(\"XSS\")</scr\u0000ipt>")

          assert_equal("<scr></scr>", fragment.to_html)
        end
      end
    end
  end
end
