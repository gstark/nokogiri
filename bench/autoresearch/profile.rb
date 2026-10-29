# frozen_string_literal: true

# Profile the pure Ruby backend. This file is not part of the timed harness.
# Usage: ruby --yjit bench/autoresearch/profile.rb parse_xml

require "vernier"
require_relative "config"

$LOAD_PATH.unshift(File.join(Autoresearch::ROOT, "lib"))
require "nokogiri"
abort "expected the pure Ruby backend" unless Nokogiri::PURE_RUBY

mode = ARGV.fetch(0, "parse_xml")
seconds = (ARGV[1] || "2").to_f

def load(name)
  File.read(File.join(Autoresearch::CORPUS_DIR, name), encoding: "UTF-8")
end

xml = load("medium_xml.xml")
html = load("medium_html.html")
ns = Autoresearch::NS_BENCH

work = case mode
when "parse_xml"
  -> { Nokogiri::XML(xml) }
when "parse_html"
  -> { Nokogiri::HTML4(html) }
when "xpath"
  doc = Nokogiri::XML(xml)
  -> { doc.xpath("//xmlns:item/xmlns:name", "xmlns" => ns).each { |node| node.text } }
when "css"
  doc = Nokogiri::HTML4(html)
  -> { doc.css("a").each { |node| node["href"]; node.text } }
when "traverse"
  doc = Nokogiri::XML(xml)
  -> { doc.traverse { |node| node.name } }
when "edit"
  doc = Nokogiri::XML(xml)
  node = doc.at_xpath("(//xmlns:item/xmlns:name)[1]", "xmlns" => ns)
  original = node.content
  -> { node.content = "bench"; node.content = original }
when "to_xml"
  doc = Nokogiri::XML(xml)
  doc.to_xml
  -> { doc.to_xml }
when "to_html"
  doc = Nokogiri::HTML4(html)
  doc.to_html
  -> { doc.to_html }
else
  abort "unknown mode #{mode}"
end

result = Vernier.profile(interval: 200) do
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    work.call
  end
end
puts result.to_markdown(top_n: 25)
