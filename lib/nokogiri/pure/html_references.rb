# frozen_string_literal: true

module Nokogiri
  module Pure
    # Character and entity references, as the libxml2 HTML parser reads them
    # before v2.14. Only the HTML 4 entity table applies. The parser does not
    # look in the DTD, and it never makes an entity reference node.
    module HTMLReferences
      module_function

      # Decode the references in string from byte +from+ up to byte +to+.
      # Each error goes to +errors+ as [message, byte offset].
      #
      # libxml2 writes a NUL byte for a reference to character 0 or to an
      # invalid character. In text it drops that byte. In an attribute value
      # the NUL ends the C string, so the rest of the value is lost.
      def decode(string, from, to, attribute, errors)
        out = +""
        pos = from
        cut = false
        while (amp = string.byteindex("&", pos)) && amp < to
          out << string.byteslice(pos, amp - pos) unless cut
          if amp + 1 < to && string.getbyte(amp + 1) == 35
            code, pos = char_ref(string, amp, to, errors)
            if code.zero?
              cut = attribute
            elsif !cut
              out << code.chr(Encoding::UTF_8)
            end
            next
          end

          stop = name_end(string, amp + 1, to)
          if stop == amp + 1
            errors << ["htmlParseEntityRef: no name", stop]
            out << "&" unless cut
            pos = stop
            next
          end

          semi = stop < to && string.getbyte(stop) == 59
          name = string.byteslice(amp + 1, stop - amp - 1)
          entity = semi ? HTML4::EntityLookup::ENTITIES[name] : nil
          errors << ["htmlParseEntityRef: expecting ';'", stop] unless semi
          if entity
            out << entity[0].chr(Encoding::UTF_8) unless cut
            pos = stop + 1
          else
            out << "&" << name unless cut
            pos = stop
          end
        end
        out << string.byteslice(pos, to - pos) if pos < to && !cut
        out
      end

      # Returns [code, next offset]. Code 0 means no character.
      def char_ref(string, amp, to, errors)
        pos = amp + 2
        hex = pos < to && (string.getbyte(pos) | 32) == 120
        pos += 1 if hex
        value = 0
        loop do
          byte = string.getbyte(pos) if pos < to
          if byte == 59
            pos += 1
            break
          end

          digit = byte && digit_value(byte, hex)
          unless digit
            errors << ["htmlParseCharRef: missing semicolon", pos]
            break
          end
          value = value * (hex ? 16 : 10) + digit if value < 0x110000
          pos += 1
        end
        return [value, pos] if xml_char?(value)

        message = if value >= 0x110000
          "htmlParseCharRef: value too large"
        else
          "htmlParseCharRef: invalid xmlChar value #{value}"
        end
        errors << [message, pos]
        [0, pos]
      end

      def digit_value(byte, hex)
        return byte - 48 if byte >= 48 && byte <= 57
        return unless hex

        lower = byte | 32
        lower - 87 if lower >= 97 && lower <= 102
      end

      def xml_char?(code)
        return code == 9 || code == 10 || code == 13 if code < 0x20
        return true if code < 0xD800

        (code >= 0xE000 && code <= 0xFFFD) || (code >= 0x10000 && code <= 0x10FFFF)
      end

      # An entity name starts with a letter, "_", or ":". A byte of 128 or
      # more counts as a letter.
      def name_end(string, from, to)
        return from if from >= to

        byte = string.getbyte(from)
        return from unless byte >= 128 || ((byte | 32) >= 97 && (byte | 32) <= 122) || byte == 95 || byte == 58

        pos = from + 1
        while pos < to
          byte = string.getbyte(pos)
          break unless byte >= 128 || ((byte | 32) >= 97 && (byte | 32) <= 122) ||
            (byte >= 48 && byte <= 57) || byte == 95 || byte == 58 || byte == 45 || byte == 46

          pos += 1
        end
        pos
      end
    end
  end
end
