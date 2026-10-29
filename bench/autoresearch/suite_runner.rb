# frozen_string_literal: true

require "nokogiri"
abort "expected the pure Ruby backend" unless Nokogiri::PURE_RUBY

root = File.expand_path("../../test", __dir__)
Dir["#{root}/**/test_*.rb"].reject { |path| path.include?("/html5/") }.sort.each { |path| require path }
