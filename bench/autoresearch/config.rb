# frozen_string_literal: true

module Autoresearch
  ROOT = File.expand_path("../..", __dir__)
  CORPUS_DIR = File.join(__dir__, "corpus")
  RUBY = ENV.fetch("NOKO_RUBY", "/home/dev/.local/share/mise/installs/ruby/3.4.7/bin/ruby")
  LIBXML_ROOT = ENV.fetch("NOKO_LIBXML_ROOT", "/tmp/nokogiri-main")
  SAMPLES = 7
  NS_BENCH = "urn:bench"
end
