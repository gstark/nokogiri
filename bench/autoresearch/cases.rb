# frozen_string_literal: true

# Fixed work list. Do not change iteration counts or case names after the
# harness commit. Both implementations must run this list unchanged.
module Autoresearch
  CASES = [
    {name: "parse_xml_small", file: "small_xml.xml", kind: :xml, op: :parse, iters: 800, warmup: 2},
    {name: "parse_xml_medium", file: "medium_xml.xml", kind: :xml, op: :parse, iters: 60, warmup: 2},
    {name: "parse_xml_large", file: "large_xml.xml", kind: :xml, op: :parse, iters: 2, warmup: 1},
    {name: "parse_html_small", file: "small_html.html", kind: :html, op: :parse, iters: 2500, warmup: 2},
    {name: "parse_html_medium", file: "medium_html.html", kind: :html, op: :parse, iters: 40, warmup: 2},
    {name: "parse_html_large", file: "large_html.html", kind: :html, op: :parse, iters: 2, warmup: 1},
    {name: "xpath_xml_medium", file: "medium_xml.xml", kind: :xml, op: :xpath, iters: 200, warmup: 2},
    {name: "css_html_medium", file: "medium_html.html", kind: :html, op: :css, iters: 800, warmup: 2},
    {name: "traverse_xml_medium", file: "medium_xml.xml", kind: :xml, op: :traverse, iters: 24, warmup: 2},
    {name: "edit_xml_medium", file: "medium_xml.xml", kind: :xml, op: :edit, iters: 60000, warmup: 2},
    {name: "serialize_xml_medium", file: "medium_xml.xml", kind: :xml, op: :to_xml, iters: 120, warmup: 2},
    {name: "serialize_html_medium", file: "medium_html.html", kind: :html, op: :to_html, iters: 120, warmup: 2}
  ].freeze
end
