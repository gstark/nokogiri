# frozen_string_literal: true

# Benchmark the operations people use most often with Nokogiri.
#
# The public docs and scraping guides start with the same steps:
# parse an HTML or XML document, search with CSS or XPath, read text and
# attributes, then serialize or edit the tree. HTML5 parsing, fragments,
# Builder, and SAX are the other entry points the project documents.
#
# benchmark-ips cannot load two copies of Nokogiri in one process.
# This file uses Job#save! so each backend runs in its own process, then
# the second process prints the comparison. The first report is "main"
# and is the baseline.
#
#   ruby benchmark/common_uses.rb
#   BENCH_WARMUP=2 BENCH_TIME=5 ruby benchmark/common_uses.rb
#   ruby benchmark/common_uses.rb --check
#   ruby benchmark/common_uses.rb --task css_scrape
#
# The pure-ruby branch must exist. The native extension on main must already
# be compiled for this Ruby. Install the timer with: gem install benchmark-ips

require "rbconfig"

module NokogiriCommonBench
  ROOT = File.expand_path("..", __dir__)
  HTML_PATH = File.join(ROOT, "test/files/tlm.html")
  ATOM_PATH = File.join(ROOT, "test/files/atom.xml")
  ATOM_NS = "http://www.w3.org/2005/Atom"
  PURE_WORKTREE = ENV.fetch("BENCH_PURE_WORKTREE", "/tmp/nokogiri-pure-ruby-bench")
  HOLD_DIR = ENV.fetch("BENCH_HOLD_DIR", "/tmp/nokogiri-bench-holds")

  # A product card, the usual fragment input for a partial template.
  FRAGMENT_HTML = <<~HTML
    <div class="product">
      <h2><a href="/products/1">Widget</a></h2>
      <span class="price">$12.00</span>
      <p>Ships in two days.</p>
    </div>
  HTML

  module_function

  def sax_counter_class
    @sax_counter_class ||= Class.new(Nokogiri::XML::SAX::Document) do
      attr_reader :count

      def initialize
        super
        @count = 0
      end

      def start_element(*)
        @count += 1
      end
    end
  end

  def html_source
    @html_source ||= File.binread(HTML_PATH)
  end

  def atom_source
    @atom_source ||= File.binread(ATOM_PATH)
  end

  def html_doc
    @html_doc ||= Nokogiri::HTML(html_source)
  end

  def atom_doc
    @atom_doc ||= Nokogiri::XML(atom_source)
  end

  def html5?
    defined?(Nokogiri::HTML5) && Nokogiri.respond_to?(:uses_gumbo?) && Nokogiri.uses_gumbo?
  end

  # Each task returns a number so the result stays live for the timer.
  def tasks
    {
      "parse_html" => lambda {
        Nokogiri::HTML(html_source).css("h2 a").length
      },
      "parse_html5" => lambda {
        return :skip unless html5?

        Nokogiri::HTML5(html_source).css("h2 a").length
      },
      "parse_xml" => lambda {
        Nokogiri::XML(atom_source).xpath("//atom:entry", "atom" => ATOM_NS).length
      },
      "css_scrape" => lambda {
        html_doc.css("div.post").inject(0) do |total, post|
          link = post.at_css("h2 a")
          next total unless link

          total + link["href"].to_s.bytesize + link.text.bytesize + post.at_css("p.postmeta").text.bytesize
        end
      },
      "at_css" => lambda {
        html_doc.at_css("title").text.bytesize
      },
      "xpath_links" => lambda {
        html_doc.xpath("//h2[@class='postitle']/a").inject(0) do |total, link|
          total + link["href"].to_s.bytesize + link.text.bytesize
        end
      },
      "serialize_html" => lambda {
        html_doc.to_html.bytesize
      },
      "serialize_xml" => lambda {
        atom_doc.to_xml.bytesize
      },
      "parse_fragment" => lambda {
        Nokogiri::HTML4::DocumentFragment.parse(FRAGMENT_HTML).at_css("a")["href"].bytesize
      },
      "build_xml" => lambda {
        builder = Nokogiri::XML::Builder.new do |xml|
          xml.feed("xmlns" => ATOM_NS) do
            xml.title("Example")
            8.times do |index|
              xml.entry do
                xml.title("Item #{index}")
                xml.link("href" => "/items/#{index}")
              end
            end
          end
        end
        builder.to_xml.bytesize
      },
      "edit_document" => lambda {
        copy = html_doc.dup
        copy.at_css("title").content = "Updated title"
        copy.at_css("body").add_child("<p class=\"note\">Read this first.</p>")
        copy.to_html.bytesize
      },
      "atom_titles" => lambda {
        feed = Nokogiri::XML(atom_source)
        feed.remove_namespaces!
        feed.css("entry > title").inject(0) { |total, node| total + node.text.bytesize }
      },
      "sax_html" => lambda {
        counter = sax_counter_class.new
        Nokogiri::HTML4::SAX::Parser.new(counter).parse(html_source)
        counter.count
      },
    }
  end

  def run_check(name)
    value = tasks.fetch(name).call
    if value == :skip
      puts "SKIP #{name}"
      return 0
    end

    puts "OK #{name} #{value}"
    0
  end

  def run_timed(name)
    work = tasks.fetch(name)
    if work.call == :skip
      puts "SKIP #{name}"
      return 0
    end

    label = ENV.fetch("BENCH_LABEL")
    hold = ENV.fetch("BENCH_HOLD")
    warmup = Float(ENV.fetch("BENCH_WARMUP", "1"))
    seconds = Float(ENV.fetch("BENCH_TIME", "2"))

    Benchmark.ips do |job|
      job.config(warmup: warmup, time: seconds)
      job.report(label) { work.call }
      job.save!(hold)
      job.compare!(order: :baseline)
    end
    0
  end
end

if ENV["BENCH_CHILD"] == "1"
  require "nokogiri"
  require "benchmark/ips"

  task_name = ENV.fetch("BENCH_TASK")
  status = ENV["BENCH_CHECK"] == "1" ? NokogiriCommonBench.run_check(task_name) : NokogiriCommonBench.run_timed(task_name)
  exit status
end

require "fileutils"

module NokogiriCommonBench
  module_function

  def ruby_bin
    ENV.fetch("BENCH_RUBY", RbConfig.ruby)
  end

  def warmup_seconds
    Float(ENV.fetch("BENCH_WARMUP", "1"))
  end

  def measure_seconds
    Float(ENV.fetch("BENCH_TIME", "2"))
  end

  def pure_lib
    marker = File.join(PURE_WORKTREE, "lib/nokogiri/pure/boot.rb")
    return File.join(PURE_WORKTREE, "lib") if File.file?(marker)

    FileUtils.rm_rf(PURE_WORKTREE) if File.directory?(PURE_WORKTREE)
    command = ["git", "worktree", "add", "--detach", PURE_WORKTREE, "pure-ruby"]
    ok = system(*command, chdir: ROOT)
    abort "Cannot create the pure-ruby worktree" unless ok

    File.join(PURE_WORKTREE, "lib")
  end

  def main_lib
    File.join(ROOT, "lib")
  end

  def selected_tasks
    names = tasks.keys
    only = ARGV.include?("--task") ? ARGV[ARGV.index("--task") + 1] : nil
    abort "Unknown task #{only}" if only && !names.include?(only)

    only ? [only] : names
  end

  def run_child(lib, label, task_name, hold)
    env = {
      "BENCH_CHILD" => "1",
      "BENCH_LABEL" => label,
      "BENCH_TASK" => task_name,
      "BENCH_HOLD" => hold,
      "BENCH_WARMUP" => warmup_seconds.to_s,
      "BENCH_TIME" => measure_seconds.to_s,
      "BENCH_CHECK" => ARGV.include?("--check") ? "1" : "0",
      "PATH" => ENV["PATH"].to_s,
    }
    script = File.join(ROOT, "benchmark/common_uses.rb")
    system(env, ruby_bin, "-I", lib, script)
  end

  def identify(lib, label)
    env = {"PATH" => ENV["PATH"].to_s}
    script = <<~RUBY
      require "nokogiri"
      mode = Nokogiri.uses_libxml? ? "native libxml2" : "pure Ruby"
      gumbo = Nokogiri.respond_to?(:uses_gumbo?) && Nokogiri.uses_gumbo? ? "gumbo" : "no gumbo"
      so = $LOADED_FEATURES.grep(/nokogiri\\.so\\z/).first
      puts format("%s  ruby %s  %s  %s  %s", #{label.inspect}, RUBY_VERSION, mode, gumbo, so || "no nokogiri.so")
    RUBY
    system(env, ruby_bin, "-I", lib, "-e", script)
  end

  def compare
    check = ARGV.include?("--check")
    puts "Common Nokogiri operations"
    puts "Warmup #{warmup_seconds}s, measure #{measure_seconds}s" unless check
    identify(main_lib, "main")
    identify(pure_lib, "pure-ruby")
    puts

    FileUtils.mkdir_p(HOLD_DIR)
    failed = false
    selected_tasks.each do |name|
      hold = File.join(HOLD_DIR, "#{name}.json")
      FileUtils.rm_f(hold)
      puts "---- #{name} ----"
      unless run_child(main_lib, "main", name, hold)
        warn "main failed on #{name}"
        failed = true
        next
      end
      unless run_child(pure_lib, "pure-ruby", name, hold)
        warn "pure-ruby failed on #{name}"
        failed = true
      end
    end
    exit 1 if failed
  end
end

NokogiriCommonBench.compare
