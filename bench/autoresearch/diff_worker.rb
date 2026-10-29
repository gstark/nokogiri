# frozen_string_literal: true

# Write canonical records for one implementation.

require_relative "canon"

impl = ARGV.fetch(0)
outdir = ARGV.fetch(1)
require "nokogiri"

case impl
when "pure"
  abort "expected the pure Ruby backend" unless Nokogiri::PURE_RUBY
when "libxml"
  abort "expected the libxml backend" if defined?(Nokogiri::PURE_RUBY) && Nokogiri::PURE_RUBY
else
  abort "unknown impl #{impl}"
end

Dir.mkdir(outdir)
files = {
  "small_xml.xml" => :xml,
  "medium_xml.xml" => :xml,
  "large_xml.xml" => :xml,
  "small_html.html" => :html,
  "medium_html.html" => :html,
  "large_html.html" => :html
}

files.each do |name, kind|
  raw = Autoresearch::Canon.read_corpus(name)
  if kind == :xml
    doc = Autoresearch::Canon.parse_xml(raw)
    File.write(File.join(outdir, "sig_#{name}.txt"), Autoresearch::Canon.xml_sig(doc))
    File.write(File.join(outdir, "errors_#{name}.txt"), doc.errors.length.to_s)
  else
    doc = Autoresearch::Canon.parse_html(raw)
    File.write(File.join(outdir, "proj_#{name}.txt"), Autoresearch::Canon.html_proj(doc))
  end
end

small = Autoresearch::Canon.parse_xml(Autoresearch::Canon.read_corpus("small_xml.xml"))
File.write(File.join(outdir, "to_xml_small.txt"), small.to_xml)

medium = Autoresearch::Canon.parse_xml(Autoresearch::Canon.read_corpus("medium_xml.xml"))
File.write(File.join(outdir, "xpath_medium.txt"), Autoresearch::Canon.xpath_names(medium))
File.write(File.join(outdir, "css_medium.txt"), Autoresearch::Canon.css_names(medium))
File.write(File.join(outdir, "edit_medium.txt"), Autoresearch::Canon.edit_record(medium))
roundtrip = Autoresearch::Canon.parse_xml(medium.to_xml)
File.write(File.join(outdir, "roundtrip_medium.txt"), Autoresearch::Canon.xml_data_sig(roundtrip))

html = Autoresearch::Canon.parse_html(Autoresearch::Canon.read_corpus("medium_html.html"))
again = Autoresearch::Canon.parse_html(html.to_html)
File.write(File.join(outdir, "roundtrip_html.txt"), Autoresearch::Canon.html_proj(again))

puts "WROTE #{outdir}"
