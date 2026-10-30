# frozen_string_literal: true

module Nokogiri
  module Pure
    module Html5
      # Gumbo HTML5 tokenizer. One character token is emitted for each code point.
      class Tokenizer
        REPLACEMENT = 0xFFFD
        MAX_CHAR = 0x10FFFF
        EOF_CP = -1
        TAB_STOP = 8

        # Hoehrmann UTF-8 DFA. UTF8_ACCEPT is 0 and UTF8_REJECT is 12.
        UTF8D = [
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
          9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
          7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
          7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
          8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
          2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
          10, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 3, 3,
          11, 6, 6, 6, 5, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
          0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, 12, 12, 12, 12,
          12, 12, 12, 12, 12, 12, 12, 12, 12, 0, 12, 12, 12, 12, 12, 0,
          12, 0, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12,
          12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 12,
          12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 12, 12, 12, 12, 36,
          12, 36, 12, 12, 12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
          12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12
        ].freeze

        CP1252 = {
          0x80 => 0x20AC, 0x82 => 0x201A, 0x83 => 0x0192, 0x84 => 0x201E,
          0x85 => 0x2026, 0x86 => 0x2020, 0x87 => 0x2021, 0x88 => 0x02C6,
          0x89 => 0x2030, 0x8A => 0x0160, 0x8B => 0x2039, 0x8C => 0x0152,
          0x8E => 0x017D, 0x91 => 0x2018, 0x92 => 0x2019, 0x93 => 0x201C,
          0x94 => 0x201D, 0x95 => 0x2022, 0x96 => 0x2013, 0x97 => 0x2014,
          0x98 => 0x02DC, 0x99 => 0x2122, 0x9A => 0x0161, 0x9B => 0x203A,
          0x9C => 0x0153, 0x9E => 0x017E, 0x9F => 0x0178
        }.freeze

        # Tags with a Gumbo enum. Every other name shares :unknown.
        KNOWN_TAGS = %w[
          html head title base link meta style script noscript template
          body article section nav aside h1 h2 h3 h4 h5 h6 hgroup header
          footer address p hr pre blockquote ol ul li dl dt dd figure
          figcaption main div a em strong small s cite q dfn abbr data time
          code var samp kbd sub sup i b u mark ruby rt rp bdi bdo span br
          wbr ins del image img iframe embed object param video audio source
          track canvas map area math mi mo mn ms mtext mglyph malignmark
          annotation-xml svg foreignobject desc table caption colgroup col
          tbody thead tfoot tr td th form fieldset legend label input button
          select datalist optgroup option textarea keygen output progress
          meter details summary menu menuitem applet acronym bgsound dir
          frame frameset noframes listing xmp nextid noembed plaintext rb
          strike basefont big blink center font marquee multicol nobr spacer
          tt rtc dialog search
        ].each_with_object({}) { |name, set| set[name] = true }.freeze

        STATES = %i[
          data rcdata rawtext script_data plaintext tag_open end_tag_open
          tag_name rcdata_lt rcdata_end_tag_open rcdata_end_tag_name rawtext_lt
          rawtext_end_tag_open rawtext_end_tag_name script_data_lt
          script_data_end_tag_open script_data_end_tag_name
          script_data_escaped_start script_data_escaped_start_dash
          script_data_escaped script_data_escaped_dash
          script_data_escaped_dash_dash script_data_escaped_lt
          script_data_escaped_end_tag_open script_data_escaped_end_tag_name
          script_data_double_escaped_start script_data_double_escaped
          script_data_double_escaped_dash script_data_double_escaped_dash_dash
          script_data_double_escaped_lt script_data_double_escaped_end
          before_attr_name attr_name after_attr_name before_attr_value
          attr_value_double_quoted attr_value_single_quoted attr_value_unquoted
          after_attr_value_quoted self_closing_start_tag bogus_comment
          markup_declaration_open comment_start comment_start_dash comment
          comment_lt comment_lt_bang comment_lt_bang_dash
          comment_lt_bang_dash_dash comment_end_dash comment_end comment_end_bang
          doctype before_doctype_name doctype_name after_doctype_name
          after_doctype_public_keyword before_doctype_public_id
          doctype_public_id_double_quoted doctype_public_id_single_quoted
          after_doctype_public_id between_doctype_public_system_id
          after_doctype_system_keyword before_doctype_system_id
          doctype_system_id_double_quoted doctype_system_id_single_quoted
          after_doctype_system_id bogus_doctype cdata_section
          cdata_section_bracket cdata_section_end character_reference
          named_character_reference ambiguous_ampersand
          numeric_character_reference hexadecimal_character_reference_start
          decimal_character_reference_start hexadecimal_character_reference
          decimal_character_reference numeric_character_reference_end
        ].freeze

        ATTR_VALUE_STATES = {
          attr_value_double_quoted: true,
          attr_value_single_quoted: true,
          attr_value_unquoted: true
        }.freeze

        attr_reader :too_many_attributes

        def initialize(input, error_log, max_attributes:)
          @error_log = error_log
          @max_attributes = max_attributes
          @too_many_attributes = false
          @bytes = input.to_s.b
          @length = @bytes.bytesize
          @index = 0
          @line = 1
          @column = 1
          @state = :data
          @return_state = :data
          @reconsume = false
          @foreign = false
          @in_cdata = false
          @buffered = nil
          @resume_index = nil
          @ref_code = 0
          @last_start_tag = nil
          @tag_buffer = utf8_buffer
          @temp = utf8_buffer
          @attrs = []
          @drop_attr = false
          @is_start_tag = false
          @self_closing = false
          @tag_name = nil
          @tag_id = nil
          @doctype_name = utf8_buffer
          @public_id = utf8_buffer
          @system_id = utf8_buffer
          @has_public = false
          @has_system = false
          @force_quirks = false
          read_char
          if @current == 0xFEFF
            @index += @width
            read_char
          end
          reset_token_start
          set_mark
          reset_tag_buffer_start
        end

        attr_writer :state

        def adjusted_current_node_foreign=(value)
          @foreign = value ? true : false
        end

        def next_token
          unless @buffered.nil?
            @reconsume = true
            token = emit_char(@buffered)
            @reconsume = false
            @buffered = nil
            return token
          end

          token = maybe_emit_from_mark
          return token if token

          loop do
            token = send(@state)
            should_advance = !@reconsume
            @reconsume = false
            return token if token

            advance if should_advance
          end
        end

        private

        def utf8_buffer
          String.new(encoding: Encoding::UTF_8)
        end

        def read_char
          if @index >= @length
            @current = EOF_CP
            @width = 0
            return
          end

          codepoint = 0
          state = 0
          i = @index
          while i < @length
            byte = @bytes.getbyte(i)
            type = UTF8D[byte]
            codepoint = (state != 0) ? ((byte & 0x3F) | (codepoint << 6)) : ((0xFF >> type) & byte)
            state = UTF8D[256 + state + type]
            if state == 0
              @width = i - @index + 1
              if codepoint == 0x0D
                nxt = i + 1
                @index += 1 if nxt < @length && @bytes.getbyte(nxt) == 0x0A
                codepoint = 0x0A
              end
              @current = codepoint
              if surrogate?(codepoint)
                add_here("surrogate-in-input-stream", format("Input contains surrogate U+%04X.", codepoint))
              elsif noncharacter?(codepoint)
                add_here("noncharacter-in-input-stream", format("Input contains noncharacter U+%04X.", codepoint))
              elsif utf8_control?(codepoint) && !(ascii_space?(codepoint) || codepoint == 0)
                add_here(
                  "control-character-in-input-stream",
                  format("Input contains prohibited control code point U+%04X.", codepoint)
                )
              end
              return
            elsif state == 12
              @width = i - @index + ((i == @index) ? 1 : 0)
              @current = REPLACEMENT
              add_here("utf8-invalid", "Invalid UTF8 encoding.")
              return
            end
            i += 1
          end
          @width = @length - @index
          @current = REPLACEMENT
          add_here("utf8-truncated", "UTF8 character truncated.")
        end

        def update_position
          if @current == 0x0A
            @line += 1
            @column = 1
          elsif @current == 0x09
            @column = ((@column / TAB_STOP) + 1) * TAB_STOP
          elsif @current != EOF_CP
            @column += 1
          end
        end

        def advance
          update_position
          @index += @width
          read_char
        end

        def set_mark
          @mark_index = @index
          @mark_line = @line
          @mark_column = @column
        end

        def reset_to_mark
          @index = @mark_index
          @line = @mark_line
          @column = @mark_column
          read_char
        end

        def reset_token_start
          @token_index = @index
          @token_line = @line
          @token_column = @column
        end

        def reset_tag_buffer_start
          @buf_index = @index
          @buf_line = @line
          @buf_column = @column
        end

        def slice_utf8(index, length)
          return "" if length <= 0

          @bytes.byteslice(index, length).force_encoding(Encoding::UTF_8)
        end

        def marked_text
          slice_utf8(@mark_index, @index - @mark_index)
        end

        def reconsume(name)
          @reconsume = true
          @state = name
        end

        def whitespace?(cp)
          cp == 0x09 || cp == 0x0A || cp == 0x0C || cp == 0x20
        end

        def alpha?(cp)
          (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)
        end

        def digit?(cp)
          cp >= 0x30 && cp <= 0x39
        end

        def alnum?(cp)
          alpha?(cp) || digit?(cp)
        end

        def xdigit?(cp)
          digit?(cp) || (cp >= 0x41 && cp <= 0x46) || (cp >= 0x61 && cp <= 0x66)
        end

        def lower(cp)
          (cp >= 0x41 && cp <= 0x5A) ? cp | 32 : cp
        end

        def ascii_space?(cp)
          cp == 0x09 || cp == 0x0A || cp == 0x0C || cp == 0x0D || cp == 0x20
        end

        def utf8_control?(cp)
          cp < 0x1F || (cp >= 0x7F && cp <= 0x9F)
        end

        def surrogate?(cp)
          cp >= 0xD800 && cp <= 0xDFFF
        end

        def noncharacter?(cp)
          (cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFF) == 0xFFFE || (cp & 0xFFFF) == 0xFFFF
        end

        def ascii_printable?(cp)
          cp >= 0 && cp <= 0x7F && cp > 0x1F
        end

        def add_here(code, message)
          @error_log.add(code: code, message: message, line: @line, column: @column, byte_offset: @index)
        end

        def add_mark(code, message)
          @error_log.add(
            code: code,
            message: message,
            line: @mark_line,
            column: @mark_column,
            byte_offset: @mark_index
          )
        end

        def add_token_error(code, message)
          @error_log.add(
            code: code,
            message: message,
            line: @token_line,
            column: @token_column,
            byte_offset: @token_index
          )
        end

        def add_buf_error(code, message)
          @error_log.add(
            code: code,
            message: message,
            line: @buf_line,
            column: @buf_column,
            byte_offset: @buf_index
          )
        end

        def finish_token(token)
          advance unless @reconsume
          token.line = @token_line
          token.column = @token_column
          token.byte_offset = @token_index
          length = @index - @token_index
          # A skipped CR sits on the previous token. Drop that trailing byte.
          length -= 1 if length > 0 && @bytes.getbyte(@token_index + length - 1) == 0x0D
          token.original = slice_utf8(@token_index, length)
          reset_token_start
          token
        end

        def emit_char(cp)
          type = if @in_cdata && cp > 0
            :cdata
          else
            case cp
            when 0x09, 0x0A, 0x0D, 0x0C, 0x20 then :whitespace
            when 0 then :null
            when EOF_CP then :eof
            else :character
            end
          end
          data = (cp < 0) ? "" : cp.chr(Encoding::UTF_8)
          finish_token(Token.new(type: type, data: data))
        end

        def emit_replacement
          add_here("unexpected-null-character", "Input contains unexpected U+0000.")
          emit_char(REPLACEMENT)
        end

        def emit_eof
          emit_char(EOF_CP)
        end

        def maybe_emit_from_mark
          return nil if @resume_index.nil?
          if @index >= @resume_index
            @resume_index = nil
            return nil
          end

          emit_char(@current)
        end

        def emit_from_mark
          @resume_index = @index
          reset_to_mark
          @reconsume = false
          maybe_emit_from_mark
        end

        def append_temp(cp)
          @temp << cp
        end

        def take_temp
          text = @temp.dup
          @temp.clear
          text
        end

        def append_tag(cp, reinit)
          reset_tag_buffer_start if @tag_buffer.empty? && reinit
          @tag_buffer << cp
        end

        def append_tag_string(text, reinit)
          reset_tag_buffer_start if @tag_buffer.empty? && reinit
          @tag_buffer << text
        end

        def reinit_tag_buffer
          @tag_buffer = utf8_buffer
          reset_tag_buffer_start
        end

        def tag_id(name)
          KNOWN_TAGS[name] ? name : :unknown
        end

        def start_new_tag(is_start)
          @tag_buffer = utf8_buffer
          reset_tag_buffer_start
          @attrs = []
          @drop_attr = false
          @is_start_tag = is_start
          @self_closing = false
          @tag_name = nil
          @tag_id = nil
        end

        def finish_tag_name
          @tag_name = @tag_buffer.dup
          @tag_id = tag_id(@tag_name)
          reinit_tag_buffer
        end

        def appropriate_end_tag?
          !@last_start_tag.nil? && tag_id(@tag_buffer) == @last_start_tag
        end

        def finish_attribute_name
          if @max_attributes >= 0 && @attrs.length >= @max_attributes
            @too_many_attributes = true
            reinit_tag_buffer
            @drop_attr = true
            return
          end

          @drop_attr = false
          name = @tag_buffer.dup
          if @attrs.any? { |attr_name, _value| attr_name == name }
            add_buf_error("duplicate-attribute", "Tag contains multiple attributes with the same name.")
            reinit_tag_buffer
            @drop_attr = true
            return
          end

          @attrs << [name, utf8_buffer]
          reinit_tag_buffer
        end

        def finish_attribute_value
          if @drop_attr
            @drop_attr = false
            reinit_tag_buffer
            return
          end

          @attrs[-1][1] = @tag_buffer.dup
          reinit_tag_buffer
        end

        def abandon_tag
          @tag_name = nil
          @tag_id = nil
          @attrs = []
          @tag_buffer = utf8_buffer
          @drop_attr = false
          @self_closing = false
        end

        def emit_current_tag
          if @is_start_tag
            token = Token.new(
              type: :start_tag,
              name: @tag_name.dup,
              attrs: @attrs.map { |name, value| [name.dup, value.dup] },
              self_closing: @self_closing
            )
            @last_start_tag = @tag_id
          else
            if @self_closing
              add_token_error("end-tag-with-trailing-solidus", "End tag ends with '/>', use '>'.")
            end
            if @attrs.length > 0
              add_token_error("end-tag-with-attributes", "End tag contains attributes.")
            end
            token = Token.new(type: :end_tag, name: @tag_name.dup, attrs: [], self_closing: false)
          end
          abandon_tag
          finish_token(token)
        end

        def emit_comment
          finish_token(Token.new(type: :comment, data: take_temp))
        end

        def emit_doctype
          token = Token.new(
            type: :doctype,
            name: @doctype_name.dup,
            public_id: @public_id.dup,
            system_id: @system_id.dup,
            has_public_id: @has_public,
            has_system_id: @has_system,
            force_quirks: @force_quirks
          )
          @doctype_name = utf8_buffer
          @public_id = utf8_buffer
          @system_id = utf8_buffer
          @has_public = false
          @has_system = false
          @force_quirks = false
          finish_token(token)
        end

        def finish_doctype_name
          @doctype_name = @temp.dup
          @temp.clear
        end

        def finish_public_id
          @public_id = @temp.dup
          @temp.clear
          @has_public = true
        end

        def finish_system_id
          @system_id = @temp.dup
          @temp.clear
          @has_system = true
        end

        def init_doctype_strings
          @doctype_name = utf8_buffer
          @public_id = utf8_buffer
          @system_id = utf8_buffer
          @has_public = false
          @has_system = false
          @force_quirks = false
        end

        def consume_match?(text, sensitive)
          len = text.bytesize
          return false if @index + len > @length

          if sensitive
            len.times do |i|
              return false if @bytes.getbyte(@index + i) != text.getbyte(i)
            end
          else
            len.times do |i|
              left = @bytes.getbyte(@index + i)
              right = text.getbyte(i)
              left |= 32 if left >= 65 && left <= 90
              right |= 32 if right >= 65 && right <= 90
              return false if left != right
            end
          end
          len.times { advance }
          true
        end

        def char_ref_in_attribute?
          ATTR_VALUE_STATES[@return_state] == true
        end

        def append_marked_raw
          append_tag_string(marked_text, @return_state == :attr_value_unquoted)
        end

        def flush_raw
          if char_ref_in_attribute?
            append_marked_raw
            nil
          else
            emit_from_mark
          end
        end

        def flush_char_ref(first, extra)
          if char_ref_in_attribute?
            unquoted = @return_state == :attr_value_unquoted
            append_tag(first, unquoted)
            append_tag(extra, unquoted) unless extra.nil?
            return nil
          end
          @buffered = extra
          emit_char(first)
        end

        def entity_suffix
          remain = @length - @index
          return "" if remain <= 0

          # Named references are at most 32 characters.
          @bytes.byteslice(@index, (remain < 64) ? remain : 64).force_encoding(Encoding::UTF_8)
        end

        def accumulate_ref(base, digit)
          @ref_code = @ref_code * base + digit
          @ref_code = MAX_CHAR + 1 if @ref_code > MAX_CHAR
        end

        def eof_in_tag
          add_here("eof-in-tag", "End of input in tag.")
          abandon_tag
          emit_eof
        end

        def unexpected_null
          add_here("unexpected-null-character", "Input contains unexpected U+0000.")
        end

        def end_tag_name_body(outer)
          c = @current
          if alpha?(c)
            append_tag(lower(c), true)
            return nil
          end
          case c
          when 0x09, 0x0A, 0x0C, 0x20
            if appropriate_end_tag?
              finish_tag_name
              @state = :before_attr_name
              return nil
            end
          when 0x2F
            if appropriate_end_tag?
              finish_tag_name
              @state = :self_closing_start_tag
              return nil
            end
          when 0x3E
            if appropriate_end_tag?
              finish_tag_name
              @state = :data
              return emit_current_tag
            end
          end
          abandon_tag
          reconsume(outer)
          emit_from_mark
        end

        def script_double_boundary(match_state, fail_state)
          c = @current
          if c == 0x09 || c == 0x0A || c == 0x0C || c == 0x20 || c == 0x2F || c == 0x3E
            @state = (@temp == "script") ? match_state : fail_state
            return emit_char(c)
          end
          if alpha?(c)
            append_temp(lower(c))
            return emit_char(c)
          end
          reconsume(fail_state)
          nil
        end

        def attr_value_quoted(quote, return_state)
          c = @current
          if c == quote
            @state = :after_attr_value_quoted
            return nil
          end
          case c
          when 0x26
            @state = :character_reference
            set_mark
            @return_state = return_state
            nil
          when 0
            unexpected_null
            append_tag(REPLACEMENT, false)
            nil
          when EOF_CP
            eof_in_tag
          else
            append_tag(c, false)
            nil
          end
        end

        def doctype_quoted(quote, public_id)
          c = @current
          if c == quote
            if public_id
              @state = :after_doctype_public_id
              finish_public_id
            else
              @state = :after_doctype_system_id
              finish_system_id
            end
            return nil
          end
          case c
          when 0
            unexpected_null
            append_temp(REPLACEMENT)
            nil
          when 0x3E
            if public_id
              add_here("abrupt-doctype-public-identifier", abrupt_public_message)
              finish_public_id
            else
              add_here("abrupt-doctype-system-identifier", abrupt_system_message)
              finish_system_id
            end
            @state = :data
            @force_quirks = true
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            public_id ? finish_public_id : finish_system_id
            emit_doctype
          else
            append_temp(c)
            nil
          end
        end

        def abrupt_public_message
          if @state == :doctype_public_id_double_quoted
            "DOCTYPE public identifier missing closing quotation mark (\")."
          else
            "DOCTYPE public identifier missing closing apostrophe (')."
          end
        end

        def abrupt_system_message
          if @state == :doctype_system_id_double_quoted
            "DOCTYPE system identifier missing closing quotation mark (\")."
          else
            "DOCTYPE system identifier missing closing apostrophe (')."
          end
        end

        def invalid_first_tag_message(cp)
          if ascii_printable?(cp)
            format("Invalid first character of tag name '%c'.", cp)
          else
            format("Invalid first code point of tag name U+%04X.", cp)
          end
        end

        def data
          case @current
          when 0x26
            @state = :character_reference
            set_mark
            @return_state = :data
            nil
          when 0x3C
            @state = :tag_open
            set_mark
            nil
          when 0
            unexpected_null
            emit_char(0)
          when EOF_CP
            emit_eof
          else
            emit_char(@current)
          end
        end

        def rcdata
          case @current
          when 0x26
            @state = :character_reference
            set_mark
            @return_state = :rcdata
            nil
          when 0x3C
            @state = :rcdata_lt
            set_mark
            nil
          when 0
            emit_replacement
          when EOF_CP
            emit_eof
          else
            emit_char(@current)
          end
        end

        def rawtext
          case @current
          when 0x3C
            @state = :rawtext_lt
            set_mark
            nil
          when 0
            emit_replacement
          when EOF_CP
            emit_eof
          else
            emit_char(@current)
          end
        end

        def script_data
          case @current
          when 0x3C
            @state = :script_data_lt
            set_mark
            nil
          when 0
            emit_replacement
          when EOF_CP
            emit_eof
          else
            emit_char(@current)
          end
        end

        def plaintext
          case @current
          when 0
            emit_replacement
          when EOF_CP
            emit_eof
          else
            emit_char(@current)
          end
        end

        def tag_open
          case @current
          when 0x21
            @state = :markup_declaration_open
            @temp.clear
            nil
          when 0x2F
            @state = :end_tag_open
            nil
          when 0x3F
            add_here("unexpected-question-mark-instead-of-tag-name", "Unexpected '?' where start tag name is expected.")
            @temp.clear
            reconsume(:bogus_comment)
            nil
          when EOF_CP
            add_here("eof-before-tag-name", "End of input where a tag name is expected.")
            reconsume(:data)
            emit_from_mark
          else
            if alpha?(@current)
              reconsume(:tag_name)
              start_new_tag(true)
              return nil
            end
            add_here("invalid-first-character-of-tag-name", invalid_first_tag_message(@current))
            reconsume(:data)
            emit_from_mark
          end
        end

        def end_tag_open
          case @current
          when 0x3E
            add_here("missing-end-tag-name", "Missing end tag name.")
            @state = :data
            nil
          when EOF_CP
            add_here("eof-before-tag-name", "End of input where a tag name is expected.")
            reconsume(:data)
            emit_from_mark
          else
            if alpha?(@current)
              reconsume(:tag_name)
              start_new_tag(false)
            else
              add_here("invalid-first-character-of-tag-name", invalid_first_tag_message(@current))
              reconsume(:bogus_comment)
              @temp.clear
            end
            nil
          end
        end

        def tag_name
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            finish_tag_name
            @state = :before_attr_name
            nil
          when 0x2F
            finish_tag_name
            @state = :self_closing_start_tag
            nil
          when 0x3E
            finish_tag_name
            @state = :data
            emit_current_tag
          when 0
            unexpected_null
            append_tag(REPLACEMENT, true)
            nil
          when EOF_CP
            eof_in_tag
          else
            append_tag(lower(@current), true)
            nil
          end
        end

        def rcdata_lt
          if @current == 0x2F
            @state = :rcdata_end_tag_open
            nil
          else
            reconsume(:rcdata)
            emit_from_mark
          end
        end

        def rcdata_end_tag_open
          if alpha?(@current)
            reconsume(:rcdata_end_tag_name)
            start_new_tag(false)
            nil
          else
            reconsume(:rcdata)
            emit_from_mark
          end
        end

        def rcdata_end_tag_name
          end_tag_name_body(:rcdata)
        end

        def rawtext_lt
          if @current == 0x2F
            @state = :rawtext_end_tag_open
            nil
          else
            reconsume(:rawtext)
            emit_from_mark
          end
        end

        def rawtext_end_tag_open
          if alpha?(@current)
            reconsume(:rawtext_end_tag_name)
            start_new_tag(false)
            nil
          else
            reconsume(:rawtext)
            emit_from_mark
          end
        end

        def rawtext_end_tag_name
          end_tag_name_body(:rawtext)
        end

        def script_data_lt
          if @current == 0x2F
            @state = :script_data_end_tag_open
            return nil
          end
          if @current == 0x21
            # Consume '!' before the replay so the first emitted character is '<'.
            advance
            reconsume(:script_data_escaped_start)
            return emit_from_mark
          end
          reconsume(:script_data)
          emit_from_mark
        end

        def script_data_end_tag_open
          if alpha?(@current)
            reconsume(:script_data_end_tag_name)
            start_new_tag(false)
            nil
          else
            reconsume(:script_data)
            emit_from_mark
          end
        end

        def script_data_end_tag_name
          end_tag_name_body(:script_data)
        end

        def script_data_escaped_start
          if @current == 0x2D
            @state = :script_data_escaped_start_dash
            emit_char(@current)
          else
            reconsume(:script_data)
            nil
          end
        end

        def script_data_escaped_start_dash
          if @current == 0x2D
            @state = :script_data_escaped_dash_dash
            emit_char(@current)
          else
            reconsume(:script_data)
            nil
          end
        end

        def script_data_escaped
          case @current
          when 0x2D
            @state = :script_data_escaped_dash
            emit_char(@current)
          when 0x3C
            @state = :script_data_escaped_lt
            @temp.clear
            set_mark
            nil
          when 0
            emit_replacement
          when EOF_CP
            add_here(
              "eof-in-script-html-comment-like-text",
              "End of input in text that resembles an HTML comment inside script element content."
            )
            emit_eof
          else
            emit_char(@current)
          end
        end

        def script_data_escaped_dash
          case @current
          when 0x2D
            @state = :script_data_escaped_dash_dash
            emit_char(@current)
          when 0x3C
            @state = :script_data_escaped_lt
            @temp.clear
            set_mark
            nil
          when 0
            @state = :script_data_escaped
            emit_replacement
          when EOF_CP
            add_here(
              "eof-in-script-html-comment-like-text",
              "End of input in text that resembles an HTML comment inside script element content."
            )
            emit_eof
          else
            @state = :script_data_escaped
            emit_char(@current)
          end
        end

        def script_data_escaped_dash_dash
          case @current
          when 0x2D
            emit_char(@current)
          when 0x3C
            @state = :script_data_escaped_lt
            @temp.clear
            set_mark
            nil
          when 0x3E
            @state = :script_data
            emit_char(@current)
          when 0
            @state = :script_data_escaped
            emit_replacement
          when EOF_CP
            add_here(
              "eof-in-script-html-comment-like-text",
              "End of input in text that resembles an HTML comment inside script element content."
            )
            emit_eof
          else
            @state = :script_data_escaped
            emit_char(@current)
          end
        end

        def script_data_escaped_lt
          if @current == 0x2F
            @state = :script_data_escaped_end_tag_open
            nil
          elsif alpha?(@current)
            reconsume(:script_data_double_escaped_start)
            emit_from_mark
          else
            reconsume(:script_data_escaped)
            emit_from_mark
          end
        end

        def script_data_escaped_end_tag_open
          if alpha?(@current)
            reconsume(:script_data_escaped_end_tag_name)
            start_new_tag(false)
            nil
          else
            reconsume(:script_data_escaped)
            emit_from_mark
          end
        end

        def script_data_escaped_end_tag_name
          end_tag_name_body(:script_data_escaped)
        end

        def script_data_double_escaped_start
          script_double_boundary(:script_data_double_escaped, :script_data_escaped)
        end

        def script_data_double_escaped
          case @current
          when 0x2D
            @state = :script_data_double_escaped_dash
            emit_char(@current)
          when 0x3C
            @state = :script_data_double_escaped_lt
            emit_char(@current)
          when 0
            emit_replacement
          when EOF_CP
            add_here(
              "eof-in-script-html-comment-like-text",
              "End of input in text that resembles an HTML comment inside script element content."
            )
            emit_eof
          else
            emit_char(@current)
          end
        end

        def script_data_double_escaped_dash
          case @current
          when 0x2D
            @state = :script_data_double_escaped_dash_dash
            emit_char(@current)
          when 0x3C
            @state = :script_data_double_escaped_lt
            emit_char(@current)
          when 0
            @state = :script_data_double_escaped
            emit_replacement
          when EOF_CP
            add_here(
              "eof-in-script-html-comment-like-text",
              "End of input in text that resembles an HTML comment inside script element content."
            )
            emit_eof
          else
            @state = :script_data_double_escaped
            emit_char(@current)
          end
        end

        def script_data_double_escaped_dash_dash
          case @current
          when 0x2D
            emit_char(@current)
          when 0x3C
            @state = :script_data_double_escaped_lt
            emit_char(@current)
          when 0x3E
            @state = :script_data
            emit_char(@current)
          when 0
            @state = :script_data_double_escaped
            emit_replacement
          when EOF_CP
            add_here(
              "eof-in-script-html-comment-like-text",
              "End of input in text that resembles an HTML comment inside script element content."
            )
            emit_eof
          else
            @state = :script_data_double_escaped
            emit_char(@current)
          end
        end

        def script_data_double_escaped_lt
          if @current == 0x2F
            @state = :script_data_double_escaped_end
            @temp.clear
            emit_char(@current)
          else
            reconsume(:script_data_double_escaped)
            nil
          end
        end

        def script_data_double_escaped_end
          script_double_boundary(:script_data_escaped, :script_data_double_escaped)
        end

        def before_attr_name
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x2F, 0x3E, EOF_CP
            reconsume(:after_attr_name)
            nil
          when 0x3D
            add_here("unexpected-equals-sign-before-attribute-name", "Unexpected '=' before an attribute name.")
            @state = :attr_name
            append_tag(@current, true)
            nil
          else
            reconsume(:attr_name)
            nil
          end
        end

        def attr_name
          case @current
          when 0x09, 0x0A, 0x0C, 0x20, 0x2F, 0x3E, EOF_CP
            finish_attribute_name
            reconsume(:after_attr_name)
            nil
          when 0x3D
            finish_attribute_name
            @state = :before_attr_value
            nil
          when 0
            unexpected_null
            append_tag(REPLACEMENT, true)
            nil
          when 0x22, 0x27, 0x3C
            add_here(
              "unexpected-character-in-attribute-name",
              format("Unexpected character (%c) in attribute name.", @current)
            )
            append_tag(lower(@current), true)
            nil
          else
            append_tag(lower(@current), true)
            nil
          end
        end

        def after_attr_name
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x2F
            @state = :self_closing_start_tag
            nil
          when 0x3D
            @state = :before_attr_value
            nil
          when 0x3E
            @state = :data
            emit_current_tag
          when EOF_CP
            eof_in_tag
          else
            reconsume(:attr_name)
            nil
          end
        end

        def before_attr_value
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x22
            @state = :attr_value_double_quoted
            reset_tag_buffer_start
            nil
          when 0x27
            @state = :attr_value_single_quoted
            reset_tag_buffer_start
            nil
          when 0x3E
            add_here("missing-attribute-value", "Missing attribute value.")
            @state = :data
            emit_current_tag
          else
            reconsume(:attr_value_unquoted)
            nil
          end
        end

        def attr_value_double_quoted
          attr_value_quoted(0x22, :attr_value_double_quoted)
        end

        def attr_value_single_quoted
          attr_value_quoted(0x27, :attr_value_single_quoted)
        end

        def attr_value_unquoted
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            @state = :before_attr_name
            finish_attribute_value
            nil
          when 0x26
            @state = :character_reference
            set_mark
            @return_state = :attr_value_unquoted
            nil
          when 0x3E
            @state = :data
            finish_attribute_value
            emit_current_tag
          when 0
            unexpected_null
            append_tag(REPLACEMENT, true)
            nil
          when EOF_CP
            eof_in_tag
          when 0x22, 0x27, 0x3C, 0x3D, 0x60
            add_here(
              "unexpected-character-in-unquoted-attribute-value",
              format("Unexpected character (%c) in unquoted attribute value.", @current)
            )
            append_tag(@current, true)
            nil
          else
            append_tag(@current, true)
            nil
          end
        end

        def after_attr_value_quoted
          finish_attribute_value
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            @state = :before_attr_name
            nil
          when 0x2F
            @state = :self_closing_start_tag
            nil
          when 0x3E
            @state = :data
            emit_current_tag
          when EOF_CP
            eof_in_tag
          else
            add_here("missing-whitespace-between-attributes", "Missing whitespace between attributes.")
            reconsume(:before_attr_name)
            nil
          end
        end

        def self_closing_start_tag
          case @current
          when 0x3E
            @state = :data
            @self_closing = true
            emit_current_tag
          when EOF_CP
            eof_in_tag
          else
            add_here("unexpected-solidus-in-tag", "Unexpected '/' in tag.")
            reconsume(:before_attr_name)
            nil
          end
        end

        def bogus_comment
          case @current
          when 0x3E
            @state = :data
            emit_comment
          when EOF_CP
            reconsume(:data)
            emit_comment
          when 0
            unexpected_null
            append_temp(REPLACEMENT)
            nil
          else
            append_temp(@current)
            nil
          end
        end

        def markup_declaration_open
          if consume_match?("--", true)
            reconsume(:comment_start)
            return nil
          end
          if consume_match?("DOCTYPE", false)
            reconsume(:doctype)
            init_doctype_strings
            return nil
          end
          if consume_match?("[CDATA[", true)
            if @foreign
              reconsume(:cdata_section)
              @in_cdata = true
              reset_token_start
            else
              add_token_error("cdata-in-html-content", "CDATA section outside foreign (SVG or MathML) content.")
              @temp.clear
              @temp << "[CDATA["
              reconsume(:bogus_comment)
            end
            return nil
          end
          add_here(
            "incorrectly-opened-comment",
            "Comment, DOCTYPE, or CDATA opened incorrectly, use '<!--', '<!DOCTYPE', or '<![CDATA['."
          )
          reconsume(:bogus_comment)
          @temp.clear
          nil
        end

        def comment_start
          case @current
          when 0x2D
            @state = :comment_start_dash
            nil
          when 0x3E
            closer = (@state == :comment_start) ? ">" : "->"
            add_here("abrupt-closing-of-empty-comment", "Empty comment abruptly closed by '#{closer}', use '-->'.")
            @state = :data
            emit_comment
          else
            reconsume(:comment)
            nil
          end
        end

        def comment_start_dash
          case @current
          when 0x2D
            @state = :comment_end
            nil
          when 0x3E
            closer = (@state == :comment_start) ? ">" : "->"
            add_here("abrupt-closing-of-empty-comment", "Empty comment abruptly closed by '#{closer}', use '-->'.")
            @state = :data
            emit_comment
          when EOF_CP
            add_here("eof-in-comment", "End of input in comment.")
            reconsume(:data)
            emit_comment
          else
            reconsume(:comment)
            append_temp(0x2D)
            nil
          end
        end

        def comment
          case @current
          when 0x3C
            @state = :comment_lt
            append_temp(@current)
            nil
          when 0x2D
            @state = :comment_end_dash
            nil
          when 0
            unexpected_null
            append_temp(REPLACEMENT)
            nil
          when EOF_CP
            add_here("eof-in-comment", "End of input in comment.")
            reconsume(:data)
            emit_comment
          else
            append_temp(@current)
            nil
          end
        end

        def comment_lt
          case @current
          when 0x21
            @state = :comment_lt_bang
            append_temp(@current)
            nil
          when 0x3C
            append_temp(@current)
            nil
          else
            reconsume(:comment)
            nil
          end
        end

        def comment_lt_bang
          if @current == 0x2D
            @state = :comment_lt_bang_dash
            nil
          else
            reconsume(:comment)
            nil
          end
        end

        def comment_lt_bang_dash
          if @current == 0x2D
            @state = :comment_lt_bang_dash_dash
            nil
          else
            reconsume(:comment_end_dash)
            nil
          end
        end

        def comment_lt_bang_dash_dash
          case @current
          when 0x3E, EOF_CP
            reconsume(:comment_end)
            nil
          else
            add_here("nested-comment", "Nested comment.")
            reconsume(:comment_end)
            nil
          end
        end

        def comment_end_dash
          case @current
          when 0x2D
            @state = :comment_end
            nil
          when EOF_CP
            add_here("eof-in-comment", "End of input in comment.")
            @state = :data
            emit_comment
          else
            reconsume(:comment)
            append_temp(0x2D)
            nil
          end
        end

        def comment_end
          case @current
          when 0x3E
            @state = :data
            emit_comment
          when 0x21
            @state = :comment_end_bang
            nil
          when 0x2D
            append_temp(0x2D)
            nil
          when EOF_CP
            add_here("eof-in-comment", "End of input in comment.")
            @state = :data
            emit_comment
          else
            reconsume(:comment)
            append_temp(0x2D)
            append_temp(0x2D)
            nil
          end
        end

        def comment_end_bang
          case @current
          when 0x2D
            @state = :comment_end_dash
            append_temp(0x2D)
            append_temp(0x2D)
            append_temp(0x21)
            nil
          when 0x3E
            add_here("incorrectly-closed-comment", "Comment closed incorrectly by '--!>', use '-->'.")
            @state = :data
            emit_comment
          when EOF_CP
            add_here("eof-in-comment", "End of input in comment.")
            @state = :data
            emit_comment
          else
            reconsume(:comment)
            append_temp(0x2D)
            append_temp(0x2D)
            append_temp(0x21)
            nil
          end
        end

        def doctype
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            @state = :before_doctype_name
            nil
          when 0x3E
            reconsume(:before_doctype_name)
            nil
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            @force_quirks = true
            reconsume(:data)
            emit_doctype
          else
            add_here(
              "missing-whitespace-before-doctype-name",
              "Missing whitespace between 'DOCTYPE' keyword and DOCTYPE name."
            )
            reconsume(:before_doctype_name)
            nil
          end
        end

        def before_doctype_name
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0
            unexpected_null
            @state = :doctype_name
            append_temp(REPLACEMENT)
            nil
          when 0x3E
            add_here("missing-doctype-name", "Missing DOCTYPE name.")
            @state = :data
            @force_quirks = true
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            @force_quirks = true
            reconsume(:data)
            emit_doctype
          else
            @state = :doctype_name
            append_temp(lower(@current))
            nil
          end
        end

        def doctype_name
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            @state = :after_doctype_name
            finish_doctype_name
            nil
          when 0x3E
            @state = :data
            finish_doctype_name
            emit_doctype
          when 0
            unexpected_null
            append_temp(REPLACEMENT)
            nil
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            finish_doctype_name
            emit_doctype
          else
            append_temp(lower(@current))
            nil
          end
        end

        def after_doctype_name
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x3E
            @state = :data
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            @state = :data
            @force_quirks = true
            emit_doctype
          else
            if consume_match?("PUBLIC", false)
              reconsume(:after_doctype_public_keyword)
            elsif consume_match?("SYSTEM", false)
              reconsume(:after_doctype_system_keyword)
            else
              add_here(
                "invalid-character-sequence-after-doctype-name",
                "Invalid character sequence after DOCTYPE name, expected 'PUBLIC', 'SYSTEM', or '>'."
              )
              reconsume(:bogus_doctype)
              @force_quirks = true
            end
            nil
          end
        end

        def after_doctype_public_keyword
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            @state = :before_doctype_public_id
            nil
          when 0x22
            add_here("missing-whitespace-after-doctype-public-keyword", "Missing whitespace after 'PUBLIC' keyword.")
            @state = :doctype_public_id_double_quoted
            nil
          when 0x27
            add_here("missing-whitespace-after-doctype-public-keyword", "Missing whitespace after 'PUBLIC' keyword.")
            @state = :doctype_public_id_single_quoted
            nil
          when 0x3E
            add_here("missing-doctype-public-identifier", "Missing DOCTYPE public identifier.")
            @state = :data
            @force_quirks = true
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            emit_doctype
          else
            add_here("missing-quote-before-doctype-public-identifier", "Missing quote before DOCTYPE public identifier.")
            reconsume(:bogus_doctype)
            @force_quirks = true
            nil
          end
        end

        def before_doctype_public_id
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x22
            @state = :doctype_public_id_double_quoted
            nil
          when 0x27
            @state = :doctype_public_id_single_quoted
            nil
          when 0x3E
            add_here("missing-doctype-public-identifier", "Missing DOCTYPE public identifier.")
            @state = :data
            @force_quirks = true
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            emit_doctype
          else
            add_here("missing-quote-before-doctype-public-identifier", "Missing quote before DOCTYPE public identifier.")
            reconsume(:bogus_doctype)
            @force_quirks = true
            nil
          end
        end

        def doctype_public_id_double_quoted
          doctype_quoted(0x22, true)
        end

        def doctype_public_id_single_quoted
          doctype_quoted(0x27, true)
        end

        def after_doctype_public_id
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            @state = :between_doctype_public_system_id
            nil
          when 0x3E
            @state = :data
            emit_doctype
          when 0x22
            add_here(
              "missing-whitespace-between-doctype-public-and-system-identifiers",
              "Missing whitespace between DOCTYPE public and system identifiers."
            )
            @state = :doctype_system_id_double_quoted
            nil
          when 0x27
            add_here(
              "missing-whitespace-between-doctype-public-and-system-identifiers",
              "Missing whitespace between DOCTYPE public and system identifiers."
            )
            @state = :doctype_system_id_single_quoted
            nil
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            emit_doctype
          else
            add_here(
              "missing-quote-before-doctype-system-identifier",
              "Missing quote before DOCTYPE system identifier."
            )
            reconsume(:bogus_doctype)
            @force_quirks = true
            nil
          end
        end

        def between_doctype_public_system_id
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x3E
            @state = :data
            emit_doctype
          when 0x22
            @state = :doctype_system_id_double_quoted
            nil
          when 0x27
            @state = :doctype_system_id_single_quoted
            nil
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            emit_doctype
          else
            add_here(
              "missing-quote-before-doctype-system-identifier",
              "Missing quote before DOCTYPE system identifier."
            )
            reconsume(:bogus_doctype)
            @force_quirks = true
            nil
          end
        end

        def after_doctype_system_keyword
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            @state = :before_doctype_system_id
            nil
          when 0x22
            add_here("missing-whitespace-after-doctype-system-keyword", "Missing whitespace after 'SYSTEM' keyword.")
            @state = :doctype_system_id_double_quoted
            nil
          when 0x27
            add_here("missing-whitespace-after-doctype-system-keyword", "Missing whitespace after 'SYSTEM' keyword.")
            @state = :doctype_system_id_single_quoted
            nil
          when 0x3E
            add_here("missing-doctype-system-identifier", "Missing DOCTYPE system identifier.")
            @state = :data
            @force_quirks = true
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            emit_doctype
          else
            add_here("missing-quote-before-doctype-system-identifier", "Missing quote before DOCTYPE system identifier.")
            reconsume(:bogus_doctype)
            @force_quirks = true
            nil
          end
        end

        def before_doctype_system_id
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x22
            @state = :doctype_system_id_double_quoted
            nil
          when 0x27
            @state = :doctype_system_id_single_quoted
            nil
          when 0x3E
            add_here("missing-doctype-system-identifier", "Missing DOCTYPE system identifier.")
            @state = :data
            @force_quirks = true
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            emit_doctype
          else
            add_here("missing-quote-before-doctype-system-identifier", "Missing quote before DOCTYPE system identifier.")
            reconsume(:bogus_doctype)
            @force_quirks = true
            nil
          end
        end

        def doctype_system_id_double_quoted
          doctype_quoted(0x22, false)
        end

        def doctype_system_id_single_quoted
          doctype_quoted(0x27, false)
        end

        def after_doctype_system_id
          case @current
          when 0x09, 0x0A, 0x0C, 0x20
            nil
          when 0x3E
            @state = :data
            emit_doctype
          when EOF_CP
            add_here("eof-in-doctype", "End of input in DOCTYPE.")
            reconsume(:data)
            @force_quirks = true
            emit_doctype
          else
            add_here(
              "unexpected-character-after-doctype-system-identifier",
              "Unexpected character after DOCTYPE system identifier."
            )
            reconsume(:bogus_doctype)
            nil
          end
        end

        def bogus_doctype
          case @current
          when 0x3E
            @state = :data
            emit_doctype
          when 0
            unexpected_null
            nil
          when EOF_CP
            reconsume(:data)
            emit_doctype
          end
        end

        def cdata_section
          case @current
          when 0x5D
            @state = :cdata_section_bracket
            set_mark
            nil
          when EOF_CP
            add_here("eof-in-cdata", "End of input in CDATA section.")
            emit_eof
          else
            emit_char(@current)
          end
        end

        def cdata_section_bracket
          if @current == 0x5D
            @state = :cdata_section_end
            nil
          else
            reconsume(:cdata_section)
            emit_from_mark
          end
        end

        def cdata_section_end
          case @current
          when 0x5D
            # Emit one bracket, then mark the bracket that remains.
            token = emit_from_mark
            @resume_index = nil
            set_mark
            @state = :cdata_section
            token
          when 0x3E
            advance
            reset_token_start
            reconsume(:data)
            @in_cdata = false
            nil
          else
            reconsume(:cdata_section)
            emit_from_mark
          end
        end

        def character_reference
          if alnum?(@current)
            reconsume(:named_character_reference)
            return nil
          end
          if @current == 0x23
            @state = :numeric_character_reference
            return nil
          end
          reconsume(@return_state)
          flush_raw
        end

        def named_character_reference
          match = Entities.match(entity_suffix)
          if match && match[0].is_a?(Integer) && match[0] > 0 && @index + match[0] <= @length
            len = match[0]
            codepoint = match[1]
            extra = match[2]
            semicolon = @bytes.getbyte(@index + len - 1) == 0x3B
            # Keep the matched name. Gumbo leaves it in the temporary buffer.
            matched_name = slice_utf8(@index, len)
            len.times { advance }
            nxt = @current
            reconsume(@return_state)
            if char_ref_in_attribute? && !semicolon && (nxt == 0x3D || alnum?(nxt))
              @temp << matched_name
              append_marked_raw
              return nil
            end
            unless semicolon
              add_mark(
                "missing-semicolon-after-character-reference",
                "Missing semicolon after character reference '#{marked_text}'."
              )
            end
            return flush_char_ref(codepoint, extra)
          end
          reconsume(:ambiguous_ampersand)
          flush_raw
        end

        def ambiguous_ampersand
          c = @current
          if alnum?(c)
            if char_ref_in_attribute?
              append_tag(c, true)
              return nil
            end
            return emit_char(c)
          end
          if c == 0x3B
            add_mark(
              "unknown-named-character-reference",
              "Unknown named character reference '#{marked_text}'."
            )
          end
          reconsume(@return_state)
          nil
        end

        def numeric_character_reference
          @ref_code = 0
          if @current == 0x78 || @current == 0x58
            @state = :hexadecimal_character_reference_start
            nil
          else
            reconsume(:decimal_character_reference_start)
            nil
          end
        end

        def hexadecimal_character_reference_start
          if xdigit?(@current)
            reconsume(:hexadecimal_character_reference)
            return nil
          end
          add_mark(
            "absence-of-digits-in-numeric-character-reference",
            "Numeric character reference '#{marked_text}' does not contain any hexadecimal digits."
          )
          reconsume(@return_state)
          flush_raw
        end

        def decimal_character_reference_start
          if digit?(@current)
            reconsume(:decimal_character_reference)
            return nil
          end
          add_mark(
            "absence-of-digits-in-numeric-character-reference",
            "Numeric character reference '#{marked_text}' does not contain any digits."
          )
          reconsume(@return_state)
          flush_raw
        end

        def hexadecimal_character_reference
          c = @current
          if digit?(c)
            accumulate_ref(16, c - 0x30)
            return nil
          end
          if c >= 0x41 && c <= 0x46
            accumulate_ref(16, c - 0x37)
            return nil
          end
          if c >= 0x61 && c <= 0x66
            accumulate_ref(16, c - 0x57)
            return nil
          end
          if c == 0x3B
            @state = :numeric_character_reference_end
            return nil
          end
          add_mark(
            "missing-semicolon-after-character-reference",
            "Missing semicolon after character reference '#{marked_text}'."
          )
          reconsume(:numeric_character_reference_end)
          nil
        end

        def decimal_character_reference
          c = @current
          if digit?(c)
            accumulate_ref(10, c - 0x30)
            return nil
          end
          if c == 0x3B
            @state = :numeric_character_reference_end
            return nil
          end
          add_mark(
            "missing-semicolon-after-character-reference",
            "Missing semicolon after character reference '#{marked_text}'."
          )
          reconsume(:numeric_character_reference_end)
          nil
        end

        def numeric_character_reference_end
          c = @ref_code
          text = marked_text
          if c == 0
            add_mark("null-character-reference", "Numeric character reference '#{text}' references U+0000.")
            c = REPLACEMENT
          elsif c > MAX_CHAR
            add_mark(
              "character-reference-outside-unicode-range",
              "Numeric character reference '#{text}' references a code point that is outside the valid Unicode range."
            )
            c = REPLACEMENT
          elsif surrogate?(c)
            add_mark(
              "surrogate-character-reference",
              format("Numeric character reference '%s' references surrogate U+%4X.", text, c)
            )
            c = REPLACEMENT
          elsif noncharacter?(c)
            add_mark(
              "noncharacter-character-reference",
              format("Numeric character reference '%s' references noncharacter U+%04X.", text, c)
            )
          elsif c == 0x0D || (utf8_control?(c) && !ascii_space?(c))
            add_mark(
              "control-character-reference",
              format("Numeric character reference '%s' references prohibited control code point U+%04X.", text, c)
            )
            c = CP1252[c] if CP1252.key?(c)
          end
          reconsume(@return_state)
          flush_char_ref(c, nil)
        end

        STATES.each do |name|
          raise ArgumentError, "missing tokenizer state #{name}" unless private_method_defined?(name)
        end
      end
    end
  end
end
