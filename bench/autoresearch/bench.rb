# frozen_string_literal: true

# Run the pure backend and the libxml backend in separate processes.
# Print one METRIC line per case and one geomean line.

require "open3"
require_relative "config"
require_relative "cases"

def run_case(impl, case_name)
  root = (impl == "pure") ? Autoresearch::ROOT : Autoresearch::LIBXML_ROOT
  script = File.join(__dir__, "worker.rb")
  cmd = [Autoresearch::RUBY, "--yjit", "-I#{File.join(root, "lib")}", script, impl, case_name]
  stdout, stderr, status = Open3.capture3(*cmd)
  unless status.success?
    warn stderr
    warn stdout
    abort "worker #{impl} #{case_name} failed with status #{status.exitstatus}"
  end
  warn stderr unless stderr.empty?
  match = stdout.match(/TIME case=#{Regexp.escape(case_name)} median=([0-9.]+)/)
  abort "worker #{impl} #{case_name} missing TIME line: #{stdout}" unless match

  match[1].to_f
end

# Each case runs in a fresh process pair, pure then libxml, so a large
# document does not change the timing of the next case.
ratios = []
Autoresearch::CASES.each do |spec|
  name = spec[:name]
  pure = run_case("pure", name)
  libxml = run_case("libxml", name)
  ratio = pure / libxml
  ratios << ratio
  puts format("METRIC case=%s ratio=%.6f", name, ratio)
  $stdout.flush
end
geomean = Math.exp(ratios.sum { |ratio| Math.log(ratio) } / ratios.length)
puts format("METRIC geomean_ratio=%.6f", geomean)
