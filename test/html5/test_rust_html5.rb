# frozen_string_literal: true

require "helper"

class TestRustHtml5 < Nokogiri::TestCase
  OPTIONS = [400, 0, 400, 0, nil, nil, nil, 0, 0].freeze

  def setup
    super
    skip("the Rust HTML5 tree builder is not loaded") unless defined?(Nokogiri::Pure::RustHtml5)
  end

  def test_ruby_error_during_attach_raises_and_clears_parent
    doc = Nokogiri::HTML5::Document.new
    def doc.xml_namespace = raise(ArgumentError, "boom")

    error = assert_raises(ArgumentError) do
      Nokogiri::Pure::RustHtml5.tree("<p>a</p><svg xml:lang='en'></svg>", OPTIONS, doc)
    end

    assert_equal("boom", error.message)
    assert_empty(doc.children)
    refute(GC.enable, "GC must be enabled after the error")
  end

  def test_gc_state_is_restored
    doc = Nokogiri::HTML5::Document.new

    GC.disable
    result = Nokogiri::Pure::RustHtml5.tree("<p>a</p>", OPTIONS, doc)

    assert(GC.enable, "GC must stay disabled when the caller disabled it")
    assert_equal(true, result["attached"])
    refute(GC.enable, "GC must be enabled after the call")
  ensure
    GC.enable
  end
end
