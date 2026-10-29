# frozen_string_literal: true

# Time one implementation. The parent process starts this file twice.
# Print one TIME line per case on stdout.

require_relative "config"
require_relative "cases"

impl = ARGV.fetch(0)
only = ARGV[1]
require "nokogiri"

unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  abort "YJIT is off"
end

case impl
when "pure"
  abort "expected the pure Ruby backend" unless Nokogiri::PURE_RUBY
when "libxml"
  abort "expected the libxml backend" if defined?(Nokogiri::PURE_RUBY) && Nokogiri::PURE_RUBY
else
  abort "unknown impl #{impl}"
end

selected = Autoresearch::CASES
if only
  selected = selected.select { |spec| spec[:name] == only }
  abort "unknown case #{only}" if selected.empty?
end

corpus = {}
selected.each do |spec|
  name = spec[:file]
  corpus[name] ||= File.read(File.join(Autoresearch::CORPUS_DIR, name), encoding: "UTF-8")
end

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def median(samples)
  ordered = samples.sort
  ordered[ordered.length / 2]
end

NS = Autoresearch::NS_BENCH

selected.each do |spec|
  raw = corpus[spec[:file]]
  iters = spec[:iters]
  doc = nil
  node = nil
  original = nil
  case spec[:op]
  when :xpath, :traverse, :to_xml
    doc = Nokogiri::XML(raw)
  when :css, :to_html
    doc = Nokogiri::HTML4(raw)
  when :edit
    doc = Nokogiri::XML(raw)
    node = doc.at_xpath("(//xmlns:item/xmlns:name)[1]", "xmlns" => NS)
    original = node.content
  end

  run = case spec[:op]
  when :parse
    if spec[:kind] == :xml
      lambda do
        acc = 0
        i = 0
        while i < iters
          parsed = Nokogiri::XML(raw)
          acc += parsed.root.name.bytesize
          i += 1
        end
        acc
      end
    else
      lambda do
        acc = 0
        i = 0
        while i < iters
          parsed = Nokogiri::HTML4(raw)
          acc += parsed.root.name.bytesize
          i += 1
        end
        acc
      end
    end
  when :xpath
    lambda do
      acc = 0
      i = 0
      while i < iters
        doc.xpath("//xmlns:item/xmlns:name", "xmlns" => NS).each { |item| acc += item.text.bytesize }
        i += 1
      end
      acc
    end
  when :css
    lambda do
      acc = 0
      i = 0
      while i < iters
        doc.css("a").each { |item|
          href = item["href"]
          acc += href.bytesize if href
          acc += item.text.bytesize
        }
        i += 1
      end
      acc
    end
  when :traverse
    lambda do
      acc = 0
      i = 0
      while i < iters
        doc.traverse { |item| acc += item.name.bytesize }
        i += 1
      end
      acc
    end
  when :edit
    lambda do
      acc = 0
      i = 0
      while i < iters
        node.content = "bench"
        node.content = original
        acc += node.content.bytesize
        i += 1
      end
      acc
    end
  when :to_xml
    lambda do
      acc = 0
      i = 0
      while i < iters
        acc += doc.to_xml.bytesize
        i += 1
      end
      acc
    end
  when :to_html
    lambda do
      acc = 0
      i = 0
      while i < iters
        acc += doc.to_html.bytesize
        i += 1
      end
      acc
    end
  else
    abort "unknown op #{spec[:op]}"
  end

  spec[:warmup].times { run.call }
  # One collection after warmup. A collection before every sample made the
  # median jump between runs.
  GC.start
  samples = Array.new(Autoresearch::SAMPLES) {
    started = clock
    run.call
    clock - started
  }
  med = median(samples)
  spread = (samples.max - samples.min) / med
  printf "TIME case=%s median=%.9f samples=%s\n", spec[:name], med, samples.map { |value| format("%.9f", value) }.join(",")
  warn format("DETAIL case=%s median=%.6f spread=%.4f", spec[:name], med, spread)
  $stdout.flush
end
