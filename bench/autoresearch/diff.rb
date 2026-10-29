# frozen_string_literal: true

# Compare pure Ruby output with libxml output. Exit 0 only when every record matches.

require "fileutils"
require "open3"
require "tmpdir"
require_relative "config"

def run_worker(impl, outdir)
  root = (impl == "pure") ? Autoresearch::ROOT : Autoresearch::LIBXML_ROOT
  script = File.join(__dir__, "diff_worker.rb")
  cmd = [Autoresearch::RUBY, "--yjit", "-I#{File.join(root, "lib")}", script, impl, outdir]
  stdout, stderr, status = Open3.capture3(*cmd)
  return if status.success?

  warn stdout
  warn stderr
  abort "diff worker #{impl} failed with status #{status.exitstatus}"
end

def report(label, left, right)
  if left == right
    puts "PASS #{label}"
    true
  else
    puts "FAIL #{label}"
    left_lines = left.lines
    right_lines = right.lines
    limit = [left_lines.length, right_lines.length].max
    shown = 0
    limit.times do |index|
      break if shown == 8
      next if left_lines[index] == right_lines[index]

      puts "  pure:   #{left_lines[index].to_s.inspect}"
      puts "  libxml: #{right_lines[index].to_s.inspect}"
      shown += 1
    end
    false
  end
end

Dir.mktmpdir("noko-diff") do |dir|
  pure_dir = File.join(dir, "pure")
  libxml_dir = File.join(dir, "libxml")
  run_worker("pure", pure_dir)
  run_worker("libxml", libxml_dir)
  names = Dir.children(pure_dir).sort
  missing = names - Dir.children(libxml_dir)
  extra = Dir.children(libxml_dir) - names
  abort "diff outputs differ: missing=#{missing} extra=#{extra}" unless missing.empty? && extra.empty?

  ok = true
  names.each do |name|
    left = File.read(File.join(pure_dir, name), encoding: "UTF-8")
    right = File.read(File.join(libxml_dir, name), encoding: "UTF-8")
    ok &&= report(name, left, right)
  end
  if ok
    puts "PASS differential"
    exit 0
  end
  puts "FAIL differential"
  exit 1
end
