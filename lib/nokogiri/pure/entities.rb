# frozen_string_literal: true

module Nokogiri
  module Pure
    # Character escaping shared by the parser and the serializer.
    module Entities
      PREDEFINED = {
        "lt" => "<",
        "gt" => ">",
        "amp" => "&",
        "quot" => "\"",
        "apos" => "'",
      }.freeze
      TEXT_ESCAPE = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;" }.freeze
      ATTR_ESCAPE = TEXT_ESCAPE.merge('"' => "&quot;").freeze
      HTML_ATTR_ESCAPE = TEXT_ESCAPE.merge('"' => "%22").freeze
      TEXT_PATTERN = /[&<>]/
      ATTR_PATTERN = /[&<>"]/

      module_function

      def escape_text(string)
        string.to_s.gsub(TEXT_PATTERN, TEXT_ESCAPE)
      end

      def escape_attr(string, percent_quotes: false)
        map = percent_quotes ? HTML_ATTR_ESCAPE : ATTR_ESCAPE
        string.to_s.gsub(ATTR_PATTERN, map)
      end

      # Decode predefined entities and character references.
      # Unknown entity references stay in the string.
      def decode_predefined(string)
        string.to_s.gsub(/&(?:#(\d+)|#x([0-9A-Fa-f]+)|([A-Za-z][A-Za-z0-9.-]*));/) do
          if (decimal = Regexp.last_match(1))
            codepoint_char(decimal.to_i)
          elsif (hex = Regexp.last_match(2))
            codepoint_char(hex.to_i(16))
          elsif (name = Regexp.last_match(3)) && PREDEFINED.key?(name)
            PREDEFINED[name]
          else
            Regexp.last_match(0)
          end
        end
      end

      def codepoint_char(code)
        return "\uFFFD" if code <= 0 || code > 0x10FFFF

        code.chr(Encoding::UTF_8)
      rescue RangeError
        "\uFFFD"
      end
    end

    # Turn parser input into UTF-8 and report the document encoding label.
    module Text
      module_function

      def transcode_input(string, encoding_hint)
        raw = strip_utf8_bom(string.to_s.dup)
        if utf16?(raw.encoding)
          return [raw.encode(Encoding::UTF_8), nonempty(encoding_hint)]
        end

        label = nonempty(encoding_hint) || sniff_encoding(raw) || inherited_label(raw)
        [convert(raw, label), label]
      end

      def nonempty(value)
        text = value&.to_s
        return if text.nil? || text.empty?

        text
      end

      def utf16?(encoding)
        [Encoding::UTF_16, Encoding::UTF_16LE, Encoding::UTF_16BE].include?(encoding)
      end

      def strip_utf8_bom(raw)
        return raw unless raw.bytesize >= 3
        return raw unless raw.getbyte(0) == 0xEF && raw.getbyte(1) == 0xBB && raw.getbyte(2) == 0xBF

        stripped = raw.byteslice(3..) || +""
        stripped.force_encoding(raw.encoding)
        stripped
      end

      def sniff_encoding(raw)
        if raw.bytesize >= 2 && raw.getbyte(0) == 0xFF && raw.getbyte(1) == 0xFE
          return "UTF-16"
        end
        return "UTF-16" if raw.bytesize >= 2 && raw.getbyte(0) == 0xFE && raw.getbyte(1) == 0xFF

        head = raw.b.byteslice(0, 256).to_s
        return unless head.start_with?("<?xml") || head.start_with?("<html") || head.include?("charset")

        match = head.match(/encoding\s*=\s*["']([^"']+)["']/) ||
          head.match(/charset\s*=\s*["']?([^"'\s>]+)/i)
        match && match[1]
      end

      def inherited_label(raw)
        encoding = raw.encoding
        return if [Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT, Encoding::BINARY].include?(encoding)

        encoding.name
      end

      def convert(raw, label)
        return to_utf8(raw) if label.nil?

        coded = raw.dup
        coded.force_encoding(Encoding.find(label))
        coded.encode(Encoding::UTF_8)
      rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError, Encoding::ConverterNotFoundError
        to_utf8(raw)
      end

      def to_utf8(raw)
        return raw if raw.encoding == Encoding::UTF_8 && raw.valid_encoding?
        return raw.encode(Encoding::UTF_8) if raw.encoding != Encoding::ASCII_8BIT && raw.valid_encoding?

        raw.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
