# frozen_string_literal: true

module Nokogiri
  module HTML4
    # Libxml2's parser has poor support for encoding detection.  First, it does not recognize the
    # HTML5 style meta charset declaration.  Secondly, even if it successfully detects an encoding
    # hint, it does not re-decode or re-parse the preceding part which may be garbled.
    #
    # EncodingReader aims to perform advanced encoding detection beyond what Libxml2 does, and to
    # emulate rewinding of a stream and make Libxml2 redo parsing from the start when an encoding
    # hint is found.

    # :nodoc: all
    class EncodingReader
      # One pass: skip comments and raw text, and keep meta start tags.
      META_OR_SKIP = /<!--.*?-->|<script\b[^>]*>.*?<\/script>|<style\b[^>]*>.*?<\/style>|<meta\b(?:[^>"']+|"[^"]*"|'[^']*')*>/im
      META_ATTR = /([^\s=\/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+)))?/

      class EncodingFound < StandardError
        attr_reader :found_encoding

        def initialize(encoding)
          @found_encoding = encoding
          super(format("encoding found: %s", encoding))
        end
      end

      class SAXHandler < Nokogiri::XML::SAX::Document
        attr_reader :encoding

        def initialize
          @encoding = nil
          super
        end

        def start_element(name, attrs = [])
          return unless name == "meta"

          attr = Hash[attrs]
          (charset = attr["charset"]) &&
            (@encoding = charset)
          (http_equiv = attr["http-equiv"]) &&
            http_equiv.match(/\AContent-Type\z/i) &&
            (content = attr["content"]) &&
            (m = content.match(/;\s*charset\s*=\s*([\w-]+)/)) &&
            (@encoding = m[1])
        end
      end

      class JumpSAXHandler < SAXHandler
        def initialize(jumptag)
          @jumptag = jumptag
          super()
        end

        def start_element(name, attrs = [])
          super
          throw(@jumptag, @encoding) if @encoding
          throw(@jumptag, nil) if /\A(?:div|h1|img|p|br)\z/.match?(name)
        end
      end

      def self.detect_encoding(chunk)
        (m = chunk.match(/\A(<\?xml[ \t\r\n][^>]*>)/)) &&
          (return Nokogiri.XML(m[1]).encoding)

        if Nokogiri.jruby?
          (m = chunk.match(/(<meta\s)(.*)(charset\s*=\s*([\w-]+))(.*)/i)) &&
            (return m[4])
          catch(:encoding_found) do
            Nokogiri::HTML4::SAX::Parser.new(JumpSAXHandler.new(:encoding_found)).parse(chunk)
            nil
          end
        else
          # The SAX push parser builds a full document before the first callback.
          # A scan finds the same meta charset without that parse.
          scan_meta_charset(chunk)
        end
      end

      class << self
        private

        # Last meta charset in the chunk wins, matching SAXHandler#start_element.
        # Comments, script, and style are skipped.
        def scan_meta_charset(chunk)
          found = nil
          chunk.b.scan(META_OR_SKIP) do |token|
            next unless token.byteslice(1, 4)&.downcase == "meta"

            found = charset_from_meta(token) || found
          end
          return unless found

          found.ascii_only? ? found.force_encoding(Encoding::US_ASCII) : found
        end

        def charset_from_meta(tag)
          attrs = {}
          tag.scan(META_ATTR) do |name, double_quoted, single_quoted, bare|
            attrs[name.downcase] = double_quoted || single_quoted || bare || ""
          end
          encoding = attrs["charset"] if attrs.key?("charset") && !attrs["charset"].empty?
          http_equiv = attrs["http-equiv"]
          if http_equiv&.match?(/\AContent-Type\z/i) && (content = attrs["content"]) &&
              (match = content.match(/;\s*charset\s*=\s*([\w-]+)/))
            encoding = match[1]
          end
          encoding
        end
      end

      def initialize(io)
        @io = io
        @firstchunk = nil
        @encoding_found = nil
      end

      # This method is used by the C extension so that
      # Nokogiri::HTML4::Document#read_io() does not leak memory when
      # EncodingFound is raised.
      attr_reader :encoding_found

      def read(len)
        # no support for a call without len

        unless @firstchunk
          (@firstchunk = @io.read(len)) || return

          # This implementation expects that the first call from
          # htmlReadIO() is made with a length long enough (~1KB) to
          # achieve advanced encoding detection.
          if (encoding = EncodingReader.detect_encoding(@firstchunk))
            # The first chunk is stored for the next read in retry.
            raise @encoding_found = EncodingFound.new(encoding)
          end
        end
        @encoding_found = nil

        ret = @firstchunk.slice!(0, len)
        if (len -= ret.length) > 0
          (rest = @io.read(len)) && ret << rest
        end
        if ret.empty?
          nil
        else
          ret
        end
      end
    end
  end
end
