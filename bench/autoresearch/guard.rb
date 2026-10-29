# frozen_string_literal: true

# Guard command: differential check, then the pure Ruby test suite.

require "open3"
require_relative "config"

def run(cmd, chdir: nil, env: {})
  stdout, stderr, status = Open3.capture3(env, *cmd, chdir: chdir)
  $stdout.write(stdout)
  $stderr.write(stderr)
  status.success?
end

diff = [Autoresearch::RUBY, "--yjit", File.join(__dir__, "diff.rb")]
abort "FAIL guard" unless run(diff)

runner = File.join(__dir__, "suite_runner.rb")
suite = [
  "bundle", "exec", Autoresearch::RUBY, "--yjit",
  "-I#{Autoresearch::ROOT}/lib:#{Autoresearch::ROOT}/test",
  runner
]
env = {"PATH" => "#{File.dirname(Autoresearch::RUBY)}:#{ENV.fetch("PATH", "")}"}
abort "FAIL guard" unless run(suite, chdir: Autoresearch::LIBXML_ROOT, env: env)

puts "PASS guard"
