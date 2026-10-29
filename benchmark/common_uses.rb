# frozen_string_literal: true

# Benchmark the operations people use most often with Nokogiri.
#
# The public docs and scraping guides start with the same steps:
# parse an HTML or XML document, search with CSS or XPath, read text and
# attributes, then serialize or edit the tree. HTML5 parsing, fragments,
# Builder, and SAX are the other entry points the project documents.
#
# benchmark-ips cannot load two copies of Nokogiri in one process.
# This file uses Job#save! so each backend runs in its own process. The
# last process prints the comparison. The first report is "libxml2" and
# is the baseline.
#
#   ruby benchmark/common_uses.rb
#   BENCH_WARMUP=2 BENCH_TIME=5 ruby benchmark/common_uses.rb
#   ruby benchmark/common_uses.rb --check
#   ruby benchmark/common_uses.rb --task css_scrape
#
# Backends, in comparison order:
#   libxml2    git main, with lib/nokogiri/nokogiri.so already compiled
#   pure-ruby  git branch pure-ruby
#   xmloxide   this worktree, only when lib/nokogiri/nokogiri.so is present
#
# BENCH_LIBXML_WORKTREE defaults to /tmp/nokogiri-main.
# BENCH_PURE_WORKTREE defaults to /tmp/nokogiri-pure-ruby-bench.
# On a pure-Ruby checkout with no nokogiri.so, the pure backend is this tree.
# Install the timer with: gem install benchmark-ips

require "rbconfig"

module NokogiriCommonBench
  ROOT = File.expand_path("..", __dir__)
  HTML_PATH = File.join(ROOT, "test/files/tlm.html")
  ATOM_PATH = File.join(ROOT, "test/files/atom.xml")
  ATOM_NS = "http://www.w3.org/2005/Atom"
  LIBXML_WORKTREE = ENV.fetch("BENCH_LIBXML_WORKTREE", "/tmp/nokogiri-main")
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
      }
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
      job.compare!(order: :baseline) if ENV["BENCH_FINAL"] == "1"
    end
    0
  end
end

if ENV["BENCH_CHILD"] == "1"
  require "nokogiri"
  require "benchmark/ips"

  task_name = ENV.fetch("BENCH_TASK")
  status = (ENV["BENCH_CHECK"] == "1") ? NokogiriCommonBench.run_check(task_name) : NokogiriCommonBench.run_timed(task_name)
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

  def ensure_worktree(path, revision)
    return if File.directory?(path)

    ok = system("git", "worktree", "add", "--detach", path, revision, chdir: ROOT)
    abort "Cannot create the worktree at #{path}" unless ok
  end

  def libxml_lib
    ensure_worktree(LIBXML_WORKTREE, "main")
    so = File.join(LIBXML_WORKTREE, "lib/nokogiri/nokogiri.so")
    abort "Missing #{so}. Compile main for this Ruby before the bench." unless File.file?(so)

    File.join(LIBXML_WORKTREE, "lib")
  end

  def pure_tree
    return PURE_WORKTREE if ENV.key?("BENCH_PURE_WORKTREE")
    return ROOT if File.file?(File.join(ROOT, "lib/nokogiri/pure/boot.rb")) && !File.file?(File.join(ROOT, "lib/nokogiri/nokogiri.so"))

    PURE_WORKTREE
  end

  def pure_lib
    path = pure_tree
    ensure_worktree(path, "pure-ruby") unless File.directory?(path)
    marker = File.join(path, "lib/nokogiri/pure/boot.rb")
    abort "Missing #{marker}" unless File.file?(marker)

    File.join(path, "lib")
  end

  def xmloxide_lib
    so = File.join(ROOT, "lib/nokogiri/nokogiri.so")
    return unless File.file?(so)

    File.join(ROOT, "lib")
  end

  def backends
    rows = [
      ["libxml2", libxml_lib, LIBXML_WORKTREE],
      ["pure-ruby", pure_lib, pure_tree]
    ]
    oxide = xmloxide_lib
    rows << ["xmloxide", oxide, ROOT] if oxide
    rows
  end

  def revision(dir)
    IO.popen(["git", "-C", dir, "rev-parse", "--short", "HEAD"], &:read).strip
  end

  def selected_tasks
    names = tasks.keys
    only = ARGV.include?("--task") ? ARGV[ARGV.index("--task") + 1] : nil
    abort "Unknown task #{only}" if only && !names.include?(only)

    only ? [only] : names
  end

  def run_child(lib, label, task_name, hold, final:)
    env = {
      "BENCH_CHILD" => "1",
      "BENCH_LABEL" => label,
      "BENCH_TASK" => task_name,
      "BENCH_HOLD" => hold,
      "BENCH_WARMUP" => warmup_seconds.to_s,
      "BENCH_TIME" => measure_seconds.to_s,
      "BENCH_CHECK" => ARGV.include?("--check") ? "1" : "0",
      "BENCH_FINAL" => final ? "1" : "0",
      "NOKOGIRI_PURE" => nil,
      "PATH" => ENV["PATH"].to_s
    }
    script = File.join(ROOT, "benchmark/common_uses.rb")
    system(env, ruby_bin, "-I", lib, script)
  end

  def identify(lib, label)
    env = {"PATH" => ENV["PATH"].to_s, "NOKOGIRI_PURE" => nil}
    script = <<~RUBY
      require "nokogiri"
      mode = if defined?(Nokogiri::PURE_RUBY) && Nokogiri::PURE_RUBY
        "pure Ruby"
      elsif Nokogiri.uses_libxml?
        "libxml2"
      else
        "xmloxide"
      end
      gumbo = Nokogiri.respond_to?(:uses_gumbo?) && Nokogiri.uses_gumbo? ? "gumbo" : "no gumbo"
      so = $LOADED_FEATURES.grep(/nokogiri\\.so\\z/).first
      puts format("%s  ruby %s  %s  %s  %s", #{label.inspect}, RUBY_VERSION, mode, gumbo, so || "no nokogiri.so")
    RUBY
    system(env, ruby_bin, "-I", lib, "-e", script)
  end

  # The final backend prints the comparison. A failure there skips that
  # print, so replay the saved rows when the hold file still has results.
  def print_held_comparison(hold)
    return unless File.file?(hold) && !File.empty?(hold)

    script = <<~RUBY
      require "json"
      require "benchmark/ips"
      rows = JSON.parse(File.read(#{hold.inspect}))
      exit 0 if rows.size < 2
      reports = rows.map do |row|
        stats = Benchmark::IPS::Stats::SD.new(row["samples"], row["measured_us"], row["iter"])
        Benchmark::IPS::Report::Entry.new(row["item"], row["measured_us"], row["iter"], stats, row["cycles"])
      end
      Benchmark.compare(*reports, order: :baseline)
    RUBY
    system({"PATH" => ENV["PATH"].to_s}, ruby_bin, "-e", script)
  end

  def compare
    check = ARGV.include?("--check")
    rows = backends
    puts "Common Nokogiri operations"
    puts "Warmup #{warmup_seconds}s, measure #{measure_seconds}s" unless check
    rows.each do |label, lib, dir|
      puts format("%-10s %s", label, revision(dir))
      identify(lib, label)
    end
    puts

    FileUtils.mkdir_p(HOLD_DIR)
    failed = false
    selected_tasks.each do |name|
      hold = File.join(HOLD_DIR, "#{name}.json")
      FileUtils.rm_f(hold)
      puts "---- #{name} ----"
      rows.each_with_index do |(label, lib, _dir), index|
        final = index == rows.length - 1
        next if run_child(lib, label, name, hold, final: final)

        warn "#{label} failed on #{name}"
        failed = true
        print_held_comparison(hold) if final && !check
      end
    end
    exit 1 if failed
  end
end

NokogiriCommonBench.compare
