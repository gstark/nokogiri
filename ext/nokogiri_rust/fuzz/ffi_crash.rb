# frozen_string_literal: true

# Fork one Ruby process per input. A signal in the child is a crash.
# This exercises the Rust extension through Ruby. It does not use AddressSanitizer.

require "nokogiri"

SECONDS = (ENV["FUZZ_SECONDS"] || "20").to_i
MAX_BYTES = 16 * 1024
ROOT = File.expand_path("../../../..", __dir__)

PACKED = [400, 0, 400, 0, nil, nil, nil, 0, 0].freeze
TOKENS = [
  "<", "</", ">", "/>", "<!", "<!--", "-->", "<![CDATA[", "]]>",
  "<?", "?>", "&", "&amp;", "&#", "&#x", ";", "<a ", "<div>",
  "<svg>", "<math>", "xmlns:", "xml:lang", "\x00", "\xff", "'", '"'
].freeze

def seeds
  list = []
  Dir[File.join(ROOT, "test/files/*.{xml,html,xhtml,svg}")].each do |path|
    bytes = File.binread(path)
    list << bytes.byteslice(0, MAX_BYTES) unless bytes.empty?
  end
  list << "<p>hi</p>"
  list << "<root>t</root>"
  list
end

def mutate(bytes, rng)
  raw = bytes.b.dup
  raw = "a" if raw.empty?
  raw = raw.byteslice(0, MAX_BYTES)
  case rng.rand(7)
  when 0
    index = rng.rand(raw.bytesize)
    raw.setbyte(index, raw.getbyte(index) ^ (1 << rng.rand(8)))
  when 1
    raw.insert(rng.rand(raw.bytesize + 1), rng.rand(256).chr)
  when 2
    raw.slice!(rng.rand(raw.bytesize)) if raw.bytesize > 1
  when 3
    raw = raw.byteslice(0, rng.rand(raw.bytesize + 1))
  when 4
    raw.insert(rng.rand(raw.bytesize + 1), TOKENS.sample(random: rng))
  when 5
    raw << TOKENS.sample(random: rng)
  else
    start = rng.rand(raw.bytesize)
    width = rng.rand(1..8)
    raw[start, width] = Array.new(width) { rng.rand(256).chr }.join
  end
  raw.byteslice(0, MAX_BYTES)
end

def exercise(kind, bytes)
  case kind
  when :html
    Nokogiri::HTML5.parse(bytes)
    Nokogiri::HTML5.fragment(bytes)
    Nokogiri::Pure::RustHtml5.tree(bytes, PACKED, nil)
    parent = Nokogiri::HTML5::Document.new
    Nokogiri::Pure::RustHtml5.tree(bytes, PACKED, parent)
  when :xml
    Nokogiri::XML(bytes)
    Nokogiri::Pure::RustFlat.columns(bytes, 0)
  end
rescue
  nil
end

def one_case(kind, bytes)
  pid = fork do
    exercise(kind, bytes)
    exit!(0)
  rescue SystemStackError, NoMemoryError
    exit!(4)
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    result = Process.wait2(pid, Process::WNOHANG)
    if result
      status = result[1]
      return :crash if status.signaled? || status.exitstatus == 4

      return :ok
    end
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 3
      Process.kill("KILL", pid)
      Process.wait2(pid)
      return :timeout
    end
    sleep 0.01
  end
rescue
  Process.kill("KILL", pid) if defined?(pid) && pid
  :error
end

rng = Random.new(20_261_030)
corpus = seeds
raise "no seeds" if corpus.empty?

crashes = []
counts = Hash.new(0)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < SECONDS
  kind = rng.rand(2).zero? ? :html : :xml
  bytes = mutate(corpus.sample(random: rng), rng)
  result = one_case(kind, bytes)
  counts[result] += 1
  next unless result == :crash || result == :abort

  path = "/tmp/noko-fuzz-#{kind}-#{crashes.length}.bin"
  File.binwrite(path, bytes)
  crashes << path
  break if crashes.length >= 5
end

puts "cases #{counts.values.sum} #{counts.inspect}"
puts(crashes.empty? ? "crashes none" : "crashes #{crashes.join(" ")}")
