# frozen_string_literal: true

require "helper"
require "tempfile"
require "timeout"

module Nokogiri
  module XML
    # Behavioral locks for published Nokogiri, libxml2, and libxslt issues.
    #
    # Memory-corruption bugs in the C libraries cannot recur in the pure
    # backend. These examples lock the observable behavior: no file read, no
    # network fetch, no entity blow-up, and no stack overflow on the same
    # public calls.
    class TestSecurityRegressions < Nokogiri::TestCase
      def entity_bomb(depth:, factor:)
        parts = [%(<!ENTITY a "Z">)]
        previous = "a"
        depth.times do |index|
          name = "e#{index}"
          parts << %(<!ENTITY #{name} "#{"&amp;#{previous};" * factor}">)
          previous = name
        end
        %(<!DOCTYPE r [#{parts.join}]><r>&amp;#{previous};</r>)
      end

      def assert_finishes(limit_seconds)
        Timeout.timeout(limit_seconds) { yield }
      end

      # Billion laughs. Default XML options leave the entity reference in place.
      it "does not expand a billion-laughs document by default" do
        doc = assert_finishes(2) { Nokogiri::XML(entity_bomb(depth: 8, factor: 10)) }

        text = doc.root.to_xml
        assert_operator text.bytesize, :<, 500
        refute_includes text, "ZZ"
      end

      # XXE via a local SYSTEM identifier. Default options do not substitute it.
      it "does not read a local external entity by default" do
        file = Tempfile.new("noko-entity")
        file.write("SECRET-MARKER")
        file.close
        xml = <<~XML
          <!DOCTYPE r [<!ENTITY x SYSTEM "#{file.path}">]>
          <r>&x;</r>
        XML

        doc = Nokogiri::XML(xml)

        refute_includes doc.to_xml, "SECRET-MARKER"
        refute_includes doc.root.text, "SECRET-MARKER"
      ensure
        file&.close
        file&.unlink
      end

      # CVE-2024-40896 and the default NONET option. An http SYSTEM id must not connect.
      it "does not fetch an HTTP external entity" do
        skip("MockServer not supported") unless Nokogiri::MockServer.supported?

        refute_network_connection do |url|
          Nokogiri::XML(<<~XML)
            <!DOCTYPE r [<!ENTITY x SYSTEM "#{url}">]>
            <r>&x;</r>
          XML
        end
      end

      it "does not fetch an HTTP external entity when NOENT is set" do
        skip("MockServer not supported") unless Nokogiri::MockServer.supported?

        refute_network_connection do |url|
          Nokogiri::XML(<<~XML) { |config| config.noent }
            <!DOCTYPE r [<!ENTITY x SYSTEM "#{url}">]>
            <r>&x;</r>
          XML
        end
      end

      # GHSA-2rr5-8q37-2w7h. SAX entity substitution is off unless the caller asks.
      it "does not read a local external entity from the SAX parser" do
        file = Tempfile.new("noko-sax-entity")
        file.write("SECRET-MARKER")
        file.close
        seen = +""
        handler = Class.new(Nokogiri::XML::SAX::Document) do
          define_method(:characters) { |text| seen << text }
        end
        xml = <<~XML
          <!DOCTYPE r [<!ENTITY x SYSTEM "#{file.path}">]>
          <r>&x;</r>
        XML

        Nokogiri::XML::SAX::Parser.new(handler.new).parse(xml)

        refute_includes seen, "SECRET-MARKER"
      ensure
        file&.close
        file&.unlink
      end

      # CVE-2022-29181. A non-string, and handler return values of the wrong type, must not abort.
      it "rejects an unexpected SAX input type" do
        parser = Nokogiri::XML::SAX::Parser.new(Nokogiri::XML::SAX::Document.new)

        assert_raises(TypeError) { parser.parse(123) }
      end

      it "ignores unexpected return values from a SAX handler" do
        handler = Class.new(Nokogiri::XML::SAX::Document) do
          def start_element(*)
            :nope
          end

          def characters(*)
            123
          end
        end

        assert_nil Nokogiri::XML::SAX::Parser.new(handler.new).parse("<r>t</r>")
      end

      # GHSA-wfpw-mmfh-qq69. XInclude of an http href must not open a socket.
      it "does not open a connection for an HTTP XInclude" do
        skip("MockServer not supported") unless Nokogiri::MockServer.supported?

        refute_network_connection do |url|
          doc = Nokogiri::XML(<<~XML)
            <r xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="#{url}"/></r>
          XML
          doc.root.do_xinclude
        rescue Errno::ENOENT
          nil
        end
      end

      # CVE-2026-86144. An included document keeps the default parse options, so its
      # external entity is not substituted.
      it "does not expand an external entity inside an XInclude" do
        secret = Tempfile.new("noko-xi-secret")
        secret.write("SECRET-MARKER")
        secret.close
        included = Tempfile.new(["noko-xi", ".xml"])
        included.write(<<~XML)
          <!DOCTYPE i [<!ENTITY x SYSTEM "#{secret.path}">]>
          <i>&x;</i>
        XML
        included.close
        doc = Nokogiri::XML(<<~XML)
          <r xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="#{included.path}"/></r>
        XML

        doc.root.do_xinclude

        refute_includes doc.to_xml, "SECRET-MARKER"
      ensure
        secret&.close
        secret&.unlink
        included&.close
        included&.unlink
      end

      # XSLT parse uses NONET. GHSA-mrxw-mxhj-p664 is a libxslt use-after-free.
      # This call must still finish without a network fetch.
      it "does not fetch an HTTP entity while parsing a stylesheet" do
        skip("MockServer not supported") unless Nokogiri::MockServer.supported?

        refute_network_connection do |url|
          Nokogiri::XSLT.parse(<<~XSL)
            <!DOCTYPE xsl:stylesheet [<!ENTITY e SYSTEM "#{url}">]>
            <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:template match="/">&e;</xsl:template>
            </xsl:stylesheet>
          XSL
        rescue Nokogiri::XML::SyntaxError, RuntimeError
          nil
        end
      end

      # GHSA-v2fc-qm4h-8hqv. A null byte in a transform parameter must raise, not hang.
      it "raises when an XSLT parameter contains a null byte" do
        xsl = Nokogiri::XSLT.parse(<<~XSL)
          <?xml version="1.0"?>
          <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
            <xsl:param name="p"/>
            <xsl:template match="/"><r><xsl:value-of select="$p"/></r></xsl:template>
          </xsl:stylesheet>
        XSL
        doc = Nokogiri::XML("<root/>")

        assert_raises(ArgumentError, RuntimeError) { xsl.transform(doc, ["p", "val\x00ue"]) }
        assert_equal "root", Nokogiri::XML("<root/>").root.name
      end

      # GHSA-c4rq-3m3g-8wgx. The three tokenizer shapes must stay linear.
      it "tokenizes adversarial CSS selectors quickly" do
        payloads = [
          %([foo=") + ("\\a" * 2_000) + "x",
          %([foo=") + ("\\aaaaaa" * 400) + "x",
          ("\\aaaaaa" * 2_000) + "X"
        ]

        payloads.each do |payload|
          outcome = nil
          assert_finishes(2) do
            outcome = Nokogiri::CSS.xpath_for(payload)
          rescue Nokogiri::CSS::SyntaxError => error
            outcome = error
          end
          assert(
            outcome.is_a?(Array) || outcome.is_a?(Nokogiri::CSS::SyntaxError),
            "selector did not finish as an XPath list or a syntax error"
          )
        end
      end

      # CVE-2022-24836. Encoding detection must not backtrack on a long prologue.
      it "detects HTML encoding without backtracking" do
        html = "<?xml " + (" " * 20_000)

        doc = assert_finishes(2) { Nokogiri::HTML4(html) }

        refute_nil doc
      end

      # CVE-2025-9714. Deep nesting must raise a syntax error, not overflow the stack.
      it "rejects an XPath expression that is nested too deeply" do
        skip("the pure XPath engine enforces this depth limit") if Nokogiri.uses_libxml?

        doc = Nokogiri::XML("<r/>")
        shallow = "(" * 40 + "1" + ")" * 40

        assert_in_delta 1, doc.xpath(shallow), 0

        error = assert_raises(Nokogiri::XML::XPath::SyntaxError) do
          doc.xpath("(" * 600 + "1" + ")" * 600)
        end
        assert_includes error.message, "nested too deeply"

        assert_raises(Nokogiri::XML::XPath::SyntaxError) do
          doc.xpath(("-" * 600) + "1")
        end
      end

      # CVE-2025-24928 and CVE-2025-6021. A long QName prefix must not overflow a stack buffer.
      it "parses an element with a long namespace prefix" do
        prefix = "p" * 4_000
        doc = Nokogiri::XML(%(<#{prefix}:a xmlns:#{prefix}="urn:x">t</#{prefix}:a>))

        assert_equal "a", doc.root.name
        assert_equal "t", doc.root.text
      end

      # GHSA-qv4q-mr5r-qprj. Reader on a truncated document must raise or yield, then stay usable.
      it "reads a truncated document" do
        reader = Nokogiri::XML::Reader.new("<r><a>")
        names = []
        error = nil

        begin
          reader.each { |node| names << node.name }
        rescue Nokogiri::XML::SyntaxError => raised
          error = raised
        end

        assert(names.include?("r") || error, "reader neither yielded the root nor raised a syntax error")
        assert_equal "ok", Nokogiri::XML("<ok/>").root.name
      end

      # GHSA-wx95-c6cv-8532. Canonicalization must return a string.
      it "canonicalizes a small document" do
        text = Nokogiri::XML("<r/>").canonicalize

        assert_kind_of String, text
        assert_includes text, "r"
      end

      # GHSA-wjv4-x9w8-wm3h. root= of a non-element must raise and leave the document usable.
      it "rejects a non-element document root" do
        doc = Nokogiri::XML("<r/>")

        assert_raises(ArgumentError) { doc.root = "nope" }
        assert_raises(TypeError) { doc.root = Nokogiri::XML::Text.new("t", doc) }
        assert_equal "r", doc.root.name
      end

      # GHSA-phwj-rprq-35pp. Attribute value writes must stay on the node.
      it "updates an attribute value" do
        doc = Nokogiri::XML("<r/>")
        doc.root["id"] = "a"
        attr = doc.root.attribute("id")

        attr.value = "b"
        assert_equal "b", attr.value
        attr.content = "c"
        assert_equal "c", attr.value
      end

      # GHSA-5v8h-3h3q-446p. A failed encoding assignment must not leave the document unusable.
      it "keeps the document usable when encoding assignment raises" do
        doc = Nokogiri::XML("<r/>")
        bad = Object.new
        bad.define_singleton_method(:to_str) { raise ArgumentError, "bad enc" }

        assert_raises(ArgumentError) { doc.encoding = bad }
        assert_equal "r", doc.root.name
      end

      # GHSA-g9g8-vgvw-g3vf. Copying from a non-node must raise.
      it "rejects initialize_copy of a non-node" do
        doc = Nokogiri::XML("<r/>")

        assert_raises(TypeError) { doc.root.send(:initialize_copy_with_args, 5, 0) }
        assert_equal "r", doc.root.name
      end

      # GHSA-9cv2-cfxc-v4v2. A wrapper that was never initialized must raise, not abort.
      it "raises when a method is called on an uninitialized node" do
        node = Nokogiri::XML::Element.allocate

        error = assert_raises(RuntimeError) { node.name }
        assert_includes error.message, "pure-Ruby document state"
      end

      # GHSA-p67v-3w7g-wjg7. The context must keep its node alive across a collection.
      it "evaluates an XPath context after a garbage collection" do
        context = Nokogiri::XML::XPathContext.new(Nokogiri::XML("<r><a>1</a></r>").at("a"))
        GC.start

        assert_equal "1", context.evaluate("string(.)")
      end

      # libxml2 issue 1074. An unexpanded entity is not an element, so id() must not see it.
      it "does not treat an unexpanded entity as an ID node" do
        doc = Nokogiri::XML(<<~XML)
          <!DOCTYPE r [<!ENTITY e '<x id="secret">nope</x>'>]>
          <r id="real">&e;</r>
        XML

        assert_empty doc.xpath("id('secret')")
        assert_equal ["r"], doc.xpath("id('real')").map(&:name)
        refute_includes doc.to_xml, "nope"
      end

      # CVE-2026-0989. This backend does not load a remote RELAX NG include or externalRef.
      it "does not fetch a remote RELAX NG include" do
        skip("libxml2 RELAX NG loads trusted schema documents") if Nokogiri.uses_libxml?
        skip("MockServer not supported") unless Nokogiri::MockServer.supported?

        refute_network_connection do |url|
          Nokogiri::XML::RelaxNG.new(<<~RNG)
            <grammar xmlns="http://relaxng.org/ns/structure/1.0">
              <include href="#{url}"/>
              <start>
                <element name="r">
                  <externalRef href="#{url}/ext"/>
                </element>
              </start>
            </grammar>
          RNG
        end
      end
    end
  end
end
