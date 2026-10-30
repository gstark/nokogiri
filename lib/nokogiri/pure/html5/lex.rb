# frozen_string_literal: true

require_relative "entities"
require_relative "model"

module Nokogiri
  module Pure
    module Html5
      # HTML tokenizer. One character token is emitted for each code point.
      class Tokenizer
        REPLACEMENT = 0xFFFD
        MAX_CHAR = 0x10FFFF
        EOF = -1

        attr_accessor :state
        attr_reader :too_many_attributes

        def initialize(input, error_log, max_attributes:)
          @errors = error_log
          @max_attributes = max_attributes
          @too_many_attributes = false
          @state = :data
          @return_state = :data
          @foreign = false
          @in_cdata = false
          @reconsume = false
          @buffered = nil
          @resume = nil
          @mark = 0
          @token_start = 0
          @last_start = nil
          @buffer = +""
          @temporary = +""
          @drop_attr = false
          @ref_value = 0
          @doctype = {}
          load(input)
        end

        def adjusted_current_node_foreign=(value)
          @foreign = value ? true : false
        end

        def next_token
          if @pending_token
            token = @pending_token
            @pending_token = nil
            return token
          end
          if (token = take_buffered)
            return token
          end
          return char_token(current_cp) if emit_resume

          loop do
            token = send(@state, current_cp)
            advance = !@reconsume
            @reconsume = false
            return token if token

            step if advance
          end
        end

        private

        def load(input)
          raw = input.to_s.b
          start = 0
          if raw.bytesize >= 3 && raw.getbyte(0) == 0xEF && raw.getbyte(1) == 0xBB && raw.getbyte(2) == 0xBF
            start = 3
          end
          text = raw.byteslice(start, raw.bytesize - start).force_encoding(Encoding::UTF_8)
          text = text.scrub("\uFFFD") unless text.valid_encoding?
          text = text.gsub(/\r\n?/, "\n")
          @text = text
          @chars = []
          line = 1
          column = 1
          offset = 0
          text.each_char do |char|
            @chars << [char.ord, line, column, offset]
            offset += char.bytesize
            if char == "\n"
              line += 1
              column = 1
            elsif char == "\t"
              column = ((column / 8) + 1) * 8
            else
              column += 1
            end
          end
          @eof = [EOF, line, column, offset]
          @index = 0
        end

        def current_cp
          (@chars[@index] || @eof)[0]
        end

        def current_pos
          char = @chars[@index] || @eof
          [char[1], char[2], char[3]]
        end

        def step
          @index += 1 if @index < @chars.length
        end

        def reconsume(next_state)
          @reconsume = true
          @state = next_state
        end

        def go(next_state)
          @state = next_state
        end

        def mark
          @mark = @index
        end

        def reset_token_start
          @token_start = @index
        end

        def space?(cp)
          cp == 9 || cp == 10 || cp == 12 || cp == 32
        end

        def alpha?(cp)
          cp.between?(65, 90) || cp.between?(97, 122)
        end

        def digit?(cp)
          cp.between?(48, 57)
        end

        def alnum?(cp)
          alpha?(cp) || digit?(cp)
        end

        def lower(cp)
          cp.between?(65, 90) ? cp + 32 : cp
        end

        def ascii?(cp)
          cp.between?(0, 127)
        end

        def control?(cp)
          cp.between?(0, 0x1F) || cp == 0x7F
        end

        def c1_control?(cp)
          cp.between?(0x80, 0x9F)
        end

        def error(code, message, at = :current, codepoint = nil)
          line, column, offset = position_at(at)
          @errors.add(code: code, message: message, line: line, column: column, byte_offset: offset)
          codepoint
        end

        def position_at(at)
          index = case at
          when :mark then @mark
          when :token then @token_start
          else @index
          end
          char = @chars[index] || @eof
          [char[1], char[2], char[3]]
        end

        def slice(from, to)
          return "" if from >= @chars.length

          start = @chars[from][3]
          finish = if to >= @chars.length
            @text.bytesize
          else
            @chars[to][3]
          end
          @text.byteslice(start, finish - start)
        end

        def char_token(cp)
          type = if cp == EOF
            :eof
          elsif @in_cdata
            :cdata
          elsif cp == 0
            :null
          elsif space?(cp)
            :whitespace
          else
            :character
          end
          token = Token.new(type: type, data: (cp == EOF) ? "" : cp.chr(Encoding::UTF_8), line: start_line, column: start_column, byte_offset: start_offset)
          finish_token
          token
        end

        def start_line
          (@chars[@token_start] || @eof)[1]
        end

        def start_column
          (@chars[@token_start] || @eof)[2]
        end

        def start_offset
          (@chars[@token_start] || @eof)[3]
        end

        def finish_token
          step unless @reconsume
          reset_token_start
        end

        def emit_char(cp)
          char_token(cp)
        end

        def emit_cdata(cp)
          token = emit_char(cp)
          token.type = :cdata if cp != EOF
          token
        end

        def emit_replacement
          error("unexpected-null-character", "Input contains unexpected U+0000.")
          emit_char(REPLACEMENT)
        end

        def emit_eof
          emit_char(EOF)
        end

        def take_buffered
          return if @buffered.nil?

          cp = @buffered
          @buffered = nil
          @reconsume = true
          token = emit_char(cp)
          @reconsume = false
          token
        end

        def emit_resume
          return false unless @resume
          return false if @index >= @resume

          @resume = nil if @index + 1 >= @resume
          true
        end

        def emit_from_mark
          @resume = @index
          @index = @mark
          @reconsume = false
          @resume = nil if @index + 1 >= @resume.to_i
          emit_char(current_cp)
        end

        def data(cp)
          case cp
          when 38
            go(:character_reference)
            mark
            @return_state = :data
            nil
          when 60
            go(:tag_open)
            mark
            nil
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            emit_char(cp)
          when EOF
            emit_eof
          else
            emit_char(cp)
          end
        end

        def rcdata(cp)
          case cp
          when 38
            go(:character_reference)
            mark
            @return_state = :rcdata
            nil
          when 60
            go(:rcdata_lt)
            mark
            nil
          when 0
            emit_replacement
          when EOF
            emit_eof
          else
            emit_char(cp)
          end
        end

        def rawtext(cp)
          case cp
          when 60
            go(:rawtext_lt)
            mark
            nil
          when 0
            emit_replacement
          when EOF
            emit_eof
          else
            emit_char(cp)
          end
        end

        def script_data(cp)
          case cp
          when 60
            go(:script_lt)
            mark
            nil
          when 0
            emit_replacement
          when EOF
            emit_eof
          else
            emit_char(cp)
          end
        end

        def plaintext(cp)
          case cp
          when 0
            emit_replacement
          when EOF
            emit_eof
          else
            emit_char(cp)
          end
        end

        def tag_open(cp)
          case cp
          when 33
            go(:markup_declaration)
            @temporary = +""
            nil
          when 47
            go(:end_tag_open)
            nil
          when 63
            error("unexpected-question-mark-instead-of-tag-name", "Unexpected '?' where start tag name is expected.")
            @temporary = +""
            reconsume(:bogus_comment)
            nil
          when EOF
            error("eof-before-tag-name", "End of input where a tag name is expected.")
            reconsume(:data)
            emit_from_mark
          else
            if alpha?(cp)
              reconsume(:tag_name)
              start_tag(true)
              nil
            else
              invalid_first(cp)
              reconsume(:data)
              emit_from_mark
            end
          end
        end

        def end_tag_open(cp)
          case cp
          when 62
            error("missing-end-tag-name", "Missing end tag name.")
            go(:data)
            nil
          when EOF
            error("eof-before-tag-name", "End of input where a tag name is expected.")
            reconsume(:data)
            emit_from_mark
          else
            if alpha?(cp)
              reconsume(:tag_name)
              start_tag(false)
            else
              invalid_first(cp)
              reconsume(:bogus_comment)
              @temporary = +""
            end
            nil
          end
        end

        def invalid_first(cp)
          message = if ascii?(cp) && !control?(cp)
            "Invalid first character of tag name '#{cp.chr}'."
          else
            format("Invalid first code point of tag name U+%04X.", cp)
          end
          error("invalid-first-character-of-tag-name", message, :current, cp)
        end

        def tag_name(cp)
          case cp
          when 9, 10, 12, 32
            finish_name
            go(:before_attr_name)
            nil
          when 47
            finish_name
            go(:self_closing)
            nil
          when 62
            finish_name
            go(:data)
            emit_tag
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @buffer << REPLACEMENT.chr(Encoding::UTF_8)
            nil
          when EOF
            error("eof-in-tag", "End of input in tag.")
            emit_eof
          else
            @buffer << lower(cp).chr(Encoding::UTF_8)
            nil
          end
        end

        def start_tag(start_tag)
          @start_tag = start_tag
          @buffer = +""
          @attrs = []
          @attr_names = {}
          @self_closing = false
          @drop_attr = false
        end

        def finish_name
          @name = @buffer
          @buffer = +""
        end

        def finish_attribute_name
          if @max_attributes.between?(0, @attrs.length)
            @too_many_attributes = true
            @buffer = +""
            @drop_attr = true
            return
          end

          name = @buffer
          @buffer = +""
          if @attr_names[name]
            error("duplicate-attribute", "Tag contains multiple attributes with the same name.", :token)
            @drop_attr = true
            return
          end

          @drop_attr = false
          @attr_names[name] = true
          @attrs << [name, +""]
        end

        def finish_attribute_value
          if @drop_attr
            @drop_attr = false
            @buffer = +""
            return
          end

          @attrs[-1][1] = @buffer if @attrs[-1]
          @buffer = +""
        end

        def appropriate_end?
          !@start_tag && @last_start && @buffer == @last_start
        end

        def emit_tag
          if @start_tag
            @last_start = @name
            token = Token.new(
              type: :start_tag,
              name: @name,
              attrs: @attrs,
              self_closing: @self_closing,
              line: start_line,
              column: start_column,
              byte_offset: start_offset
            )
          else
            error("end-tag-with-trailing-solidus", "End tag ends with '/>', use '>'.", :token) if @self_closing
            error("end-tag-with-attributes", "End tag contains attributes.", :token) unless @attrs.empty?
            token = Token.new(
              type: :end_tag,
              name: @name,
              self_closing: @self_closing,
              line: start_line,
              column: start_column,
              byte_offset: start_offset
            )
          end
          finish_token
          token
        end

        def before_attr_name(cp)
          return nil if space?(cp)

          if cp == 47 || cp == 62 || cp == EOF
            reconsume(:after_attr_name)
            return nil
          end
          if cp == 61
            error("unexpected-equals-sign-before-attribute-name", "Unexpected '=' before an attribute name.")
            go(:attr_name)
            @buffer << "="
            return nil
          end
          reconsume(:attr_name)
          nil
        end

        def attr_name(cp)
          if space?(cp) || cp == 47 || cp == 62 || cp == EOF
            finish_attribute_name
            reconsume(:after_attr_name)
            return nil
          end
          if cp == 61
            finish_attribute_name
            go(:before_attr_value)
            return nil
          end
          if cp == 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @buffer << REPLACEMENT.chr(Encoding::UTF_8)
            return nil
          end
          if cp == 34 || cp == 39 || cp == 60
            error("unexpected-character-in-attribute-name", "Unexpected character (#{cp.chr}) in attribute name.")
          end
          @buffer << lower(cp).chr(Encoding::UTF_8)
          nil
        end

        def after_attr_name(cp)
          return nil if space?(cp)

          case cp
          when 47
            go(:self_closing)
          when 61
            go(:before_attr_value)
          when 62
            go(:data)
            return emit_tag
          when EOF
            error("eof-in-tag", "End of input in tag.")
            return emit_eof
          else
            reconsume(:attr_name)
          end
          nil
        end

        def before_attr_value(cp)
          return nil if space?(cp)

          case cp
          when 34
            go(:attr_double)
            @buffer = +""
          when 39
            go(:attr_single)
            @buffer = +""
          when 62
            error("missing-attribute-value", "Missing attribute value.")
            go(:data)
            return emit_tag
          else
            reconsume(:attr_unquoted)
          end
          nil
        end

        def attr_double(cp)
          quoted_attr(cp, 34, :attr_double)
        end

        def attr_single(cp)
          quoted_attr(cp, 39, :attr_single)
        end

        def quoted_attr(cp, quote, return_state)
          case cp
          when quote
            go(:after_attr_value)
            nil
          when 38
            go(:character_reference)
            mark
            @return_state = return_state
            nil
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @buffer << REPLACEMENT.chr(Encoding::UTF_8)
            nil
          when EOF
            error("eof-in-tag", "End of input in tag.")
            emit_eof
          else
            @buffer << cp.chr(Encoding::UTF_8)
            nil
          end
        end

        def attr_unquoted(cp)
          case cp
          when 9, 10, 12, 32
            go(:before_attr_name)
            finish_attribute_value
            nil
          when 38
            go(:character_reference)
            mark
            @return_state = :attr_unquoted
            nil
          when 62
            go(:data)
            finish_attribute_value
            emit_tag
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @buffer << REPLACEMENT.chr(Encoding::UTF_8)
            nil
          when EOF
            error("eof-in-tag", "End of input in tag.")
            emit_eof
          else
            if cp == 34 || cp == 39 || cp == 60 || cp == 61 || cp == 96
              error("unexpected-character-in-unquoted-attribute-value", "Unexpected character (#{cp.chr}) in unquoted attribute value.")
            end
            @buffer << cp.chr(Encoding::UTF_8)
            nil
          end
        end

        def after_attr_value(cp)
          finish_attribute_value
          case cp
          when 9, 10, 12, 32
            go(:before_attr_name)
          when 47
            go(:self_closing)
          when 62
            go(:data)
            return emit_tag
          when EOF
            error("eof-in-tag", "End of input in tag.")
            return emit_eof
          else
            error("missing-whitespace-between-attributes", "Missing whitespace between attributes.")
            reconsume(:before_attr_name)
          end
          nil
        end

        def self_closing(cp)
          case cp
          when 62
            @self_closing = true
            go(:data)
            emit_tag
          when EOF
            error("eof-in-tag", "End of input in tag.")
            emit_eof
          else
            error("unexpected-solidus-in-tag", "Unexpected '/' in tag.")
            reconsume(:before_attr_name)
            nil
          end
        end

        def rcdata_lt(cp)
          if cp == 47
            go(:rcdata_end_open)
            nil
          else
            reconsume(:rcdata)
            emit_from_mark
          end
        end

        def rcdata_end_open(cp)
          end_open(cp, :rcdata, :rcdata_end_name)
        end

        def rawtext_lt(cp)
          if cp == 47
            go(:rawtext_end_open)
            nil
          else
            reconsume(:rawtext)
            emit_from_mark
          end
        end

        def rawtext_end_open(cp)
          end_open(cp, :rawtext, :rawtext_end_name)
        end

        def script_lt(cp)
          if cp == 47
            go(:script_end_open)
            nil
          elsif cp == 33
            step
            @temporary = +""
            go(:script_escaped_start)
            emit_from_mark
          else
            reconsume(:script_data)
            emit_from_mark
          end
        end

        def script_end_open(cp)
          end_open(cp, :script_data, :script_end_name)
        end

        def end_open(cp, back, name_state)
          if alpha?(cp)
            @buffer = +""
            reconsume(name_state)
            start_tag(false)
          else
            reconsume(back)
            return emit_from_mark
          end
          nil
        end

        def rcdata_end_name(cp)
          end_name(cp, :rcdata)
        end

        def rawtext_end_name(cp)
          end_name(cp, :rawtext)
        end

        def script_end_name(cp)
          end_name(cp, :script_data)
        end

        def end_name(cp, back)
          if appropriate_end?
            if space?(cp)
              finish_name
              go(:before_attr_name)
              return nil
            elsif cp == 47
              finish_name
              go(:self_closing)
              return nil
            elsif cp == 62
              finish_name
              go(:data)
              return emit_tag
            end
          end
          if alpha?(cp)
            @buffer << lower(cp).chr(Encoding::UTF_8)
            return nil
          end
          reconsume(back)
          emit_from_mark
        end

        def script_escaped_start(cp)
          if cp == 45
            go(:script_escaped_start_dash)
            return emit_char(cp)
          end
          reconsume(:script_data)
          nil
        end

        def script_escaped_start_dash(cp)
          if cp == 45
            go(:script_escaped_dash_dash)
            return emit_char(cp)
          end
          reconsume(:script_data)
          nil
        end

        def script_escaped(cp)
          case cp
          when 45
            go(:script_escaped_dash)
            emit_char(cp)
          when 60
            go(:script_escaped_lt)
            @temporary = +""
            mark
            nil
          when 0
            emit_replacement
          when EOF
            script_eof
          else
            emit_char(cp)
          end
        end

        def script_escaped_dash(cp)
          case cp
          when 45
            go(:script_escaped_dash_dash)
            emit_char(cp)
          when 60
            go(:script_escaped_lt)
            @temporary = +""
            mark
            nil
          when 0
            go(:script_escaped)
            emit_replacement
          when EOF
            script_eof
          else
            go(:script_escaped)
            emit_char(cp)
          end
        end

        def script_escaped_dash_dash(cp)
          case cp
          when 45
            emit_char(cp)
          when 60
            go(:script_escaped_lt)
            @temporary = +""
            mark
            nil
          when 62
            go(:script_data)
            emit_char(cp)
          when 0
            go(:script_escaped)
            emit_replacement
          when EOF
            script_eof
          else
            go(:script_escaped)
            emit_char(cp)
          end
        end

        def script_escaped_lt(cp)
          if cp == 47
            go(:script_escaped_end_open)
            return nil
          end
          if alpha?(cp)
            reconsume(:script_double_escaped_start)
          else
            reconsume(:script_escaped)
          end
          emit_from_mark
        end

        def script_escaped_end_open(cp)
          end_open(cp, :script_escaped, :script_escaped_end_name)
        end

        def script_escaped_end_name(cp)
          end_name(cp, :script_escaped)
        end

        def script_double_escaped_start(cp)
          if space?(cp) || cp == 47 || cp == 62
            go((@temporary == "script") ? :script_double_escaped : :script_escaped)
            return emit_char(cp)
          end
          if alpha?(cp)
            @temporary << lower(cp).chr(Encoding::UTF_8)
            return emit_char(cp)
          end
          reconsume(:script_escaped)
          nil
        end

        def script_double_escaped(cp)
          case cp
          when 45
            go(:script_double_escaped_dash)
            emit_char(cp)
          when 60
            go(:script_double_escaped_lt)
            emit_char(cp)
          when 0
            emit_replacement
          when EOF
            script_eof
          else
            emit_char(cp)
          end
        end

        def script_double_escaped_dash(cp)
          case cp
          when 45
            go(:script_double_escaped_dash_dash)
            emit_char(cp)
          when 60
            go(:script_double_escaped_lt)
            emit_char(cp)
          when 0
            go(:script_double_escaped)
            emit_replacement
          when EOF
            script_eof
          else
            go(:script_double_escaped)
            emit_char(cp)
          end
        end

        def script_double_escaped_dash_dash(cp)
          case cp
          when 45
            emit_char(cp)
          when 60
            go(:script_double_escaped_lt)
            emit_char(cp)
          when 62
            go(:script_data)
            emit_char(cp)
          when 0
            go(:script_double_escaped)
            emit_replacement
          when EOF
            script_eof
          else
            go(:script_double_escaped)
            emit_char(cp)
          end
        end

        def script_double_escaped_lt(cp)
          if cp == 47
            go(:script_double_escaped_end)
            @temporary = +""
            return emit_char(cp)
          end
          reconsume(:script_double_escaped)
          nil
        end

        def script_double_escaped_end(cp)
          if space?(cp) || cp == 47 || cp == 62
            go((@temporary == "script") ? :script_escaped : :script_double_escaped)
            return emit_char(cp)
          end
          if alpha?(cp)
            @temporary << lower(cp).chr(Encoding::UTF_8)
            return emit_char(cp)
          end
          reconsume(:script_double_escaped)
          nil
        end

        def script_eof
          error("eof-in-script-html-comment-like-text", "End of input in script HTML comment-like text.")
          emit_eof
        end

        def bogus_comment(cp)
          case cp
          when 62
            go(:data)
            emit_comment
          when EOF
            reconsume(:data)
            emit_comment
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @temporary << REPLACEMENT.chr(Encoding::UTF_8)
            nil
          else
            @temporary << cp.chr(Encoding::UTF_8)
            nil
          end
        end

        def emit_comment
          token = Token.new(
            type: :comment,
            data: @temporary,
            line: start_line,
            column: start_column,
            byte_offset: start_offset
          )
          @temporary = +""
          finish_token
          token
        end

        def markup_declaration(cp)
          upcoming = slice(@index, @index + 7)
          if upcoming.start_with?("--")
            @index += 2
            @temporary = +""
            reconsume(:comment_start)
            return nil
          end
          if upcoming.downcase.start_with?("doctype")
            @index += 7
            reconsume(:doctype)
            return nil
          end
          if upcoming.start_with?("[CDATA[")
            if @foreign
              @index += 7
              @in_cdata = true
              reconsume(:cdata)
            else
              error("cdata-in-html-content", "CDATA section in HTML content.")
              @temporary = +""
              reconsume(:bogus_comment)
            end
            return nil
          end
          error("incorrectly-opened-comment", "Comment, DOCTYPE, or CDATA opened incorrectly, use '<!--', '<!DOCTYPE', or '<![CDATA['.")
          reconsume(:bogus_comment)
          @temporary = +""
          nil
        end

        def comment_start(cp)
          case cp
          when 45
            go(:comment_start_dash)
          when 62
            error("abrupt-closing-of-empty-comment", "Empty comment abruptly closed by '>', use '-->'.")
            go(:data)
            return emit_comment
          else
            reconsume(:comment)
          end
          nil
        end

        def comment_start_dash(cp)
          case cp
          when 45
            go(:comment_end)
          when 62
            error("abrupt-closing-of-empty-comment", "Empty comment abruptly closed by '->', use '-->'.")
            go(:data)
            return emit_comment
          when EOF
            error("eof-in-comment", "End of input in comment.")
            reconsume(:data)
            return emit_comment
          else
            @temporary << "-"
            reconsume(:comment)
          end
          nil
        end

        def comment(cp)
          case cp
          when 60
            @temporary << "<"
            go(:comment_lt)
          when 45
            go(:comment_end_dash)
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @temporary << REPLACEMENT.chr(Encoding::UTF_8)
          when EOF
            error("eof-in-comment", "End of input in comment.")
            reconsume(:data)
            return emit_comment
          else
            @temporary << cp.chr(Encoding::UTF_8)
          end
          nil
        end

        def comment_lt(cp)
          case cp
          when 33
            @temporary << "!"
            go(:comment_lt_bang)
          when 60
            @temporary << "<"
          else
            reconsume(:comment)
          end
          nil
        end

        def comment_lt_bang(cp)
          go((cp == 45) ? :comment_lt_bang_dash : :comment)
          nil
        end

        def comment_lt_bang_dash(cp)
          go((cp == 45) ? :comment_lt_bang_dash_dash : :comment_end_dash)
          nil
        end

        def comment_lt_bang_dash_dash(cp)
          error("nested-comment", "Nested comment.") unless cp == 62 || cp == EOF
          reconsume(:comment_end)
          nil
        end

        def comment_end_dash(cp)
          case cp
          when 45
            go(:comment_end)
          when EOF
            error("eof-in-comment", "End of input in comment.")
            reconsume(:data)
            return emit_comment
          else
            @temporary << "-"
            reconsume(:comment)
          end
          nil
        end

        def comment_end(cp)
          case cp
          when 62
            go(:data)
            return emit_comment
          when 33
            go(:comment_end_bang)
          when 45
            @temporary << "-"
          when EOF
            error("eof-in-comment", "End of input in comment.")
            reconsume(:data)
            return emit_comment
          else
            @temporary << "--"
            reconsume(:comment)
          end
          nil
        end

        def comment_end_bang(cp)
          case cp
          when 45
            @temporary << "--!"
            go(:comment_end_dash)
          when 62
            error("incorrectly-closed-comment", "Comment closed incorrectly by '--!>', use '-->'.")
            go(:data)
            return emit_comment
          when EOF
            error("eof-in-comment", "End of input in comment.")
            reconsume(:data)
            return emit_comment
          else
            @temporary << "--!"
            reconsume(:comment)
          end
          nil
        end

        def doctype(cp)
          case cp
          when 9, 10, 12, 32
            go(:before_doctype_name)
          when 62
            reconsume(:before_doctype_name)
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("missing-whitespace-before-doctype-name", "Missing whitespace between 'DOCTYPE' keyword and DOCTYPE name.")
            reconsume(:before_doctype_name)
          end
          nil
        end

        def before_doctype_name(cp)
          return nil if space?(cp)

          case cp
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @doctype = {name: REPLACEMENT.chr(Encoding::UTF_8), force_quirks: false}
            go(:doctype_name)
          when 62
            error("missing-doctype-name", "Missing DOCTYPE name.")
            force_quirks
            go(:data)
            return emit_doctype
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            @doctype = {name: lower(cp).chr(Encoding::UTF_8), force_quirks: false}
            go(:doctype_name)
          end
          nil
        end

        def doctype_name(cp)
          case cp
          when 9, 10, 12, 32
            go(:after_doctype_name)
          when 62
            go(:data)
            return emit_doctype
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @doctype[:name] << REPLACEMENT.chr(Encoding::UTF_8)
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            @doctype[:name] << lower(cp).chr(Encoding::UTF_8)
          end
          nil
        end

        def after_doctype_name(cp)
          return nil if space?(cp)
          upcoming = slice(@index, @index + 6)

          if upcoming.downcase.start_with?("public")
            @index += 6
            reconsume(:after_doctype_public)
            return nil
          end
          if upcoming.downcase.start_with?("system")
            @index += 6
            reconsume(:after_doctype_system)
            return nil
          end
          if cp == 62
            go(:data)
            return emit_doctype
          end
          if cp == EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          end
          error("invalid-character-sequence-after-doctype-name", "Invalid character sequence after DOCTYPE name, expected 'PUBLIC', 'SYSTEM', or '>'.")
          force_quirks
          reconsume(:bogus_doctype)
          nil
        end

        def after_doctype_public(cp)
          if space?(cp)
            go(:before_doctype_public)
          elsif cp == 34
            error("missing-whitespace-after-doctype-public-keyword", "Missing whitespace after 'PUBLIC' keyword.")
            @temporary = +""
            @doctype[:has_public_id] = true
            go(:doctype_public_double)
          elsif cp == 39
            error("missing-whitespace-after-doctype-public-keyword", "Missing whitespace after 'PUBLIC' keyword.")
            @temporary = +""
            @doctype[:has_public_id] = true
            go(:doctype_public_single)
          elsif cp == 62
            error("missing-doctype-public-identifier", "Missing DOCTYPE public identifier.")
            force_quirks
            go(:data)
            return emit_doctype
          elsif cp == EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("missing-quote-before-doctype-public-identifier", "Missing quote before DOCTYPE public identifier.")
            force_quirks
            reconsume(:bogus_doctype)
          end
          nil
        end

        def before_doctype_public(cp)
          return nil if space?(cp)

          case cp
          when 34
            @temporary = +""
            @doctype[:has_public_id] = true
            go(:doctype_public_double)
          when 39
            @temporary = +""
            @doctype[:has_public_id] = true
            go(:doctype_public_single)
          when 62
            error("missing-doctype-public-identifier", "Missing DOCTYPE public identifier.")
            force_quirks
            go(:data)
            return emit_doctype
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("missing-quote-before-doctype-public-identifier", "Missing quote before DOCTYPE public identifier.")
            force_quirks
            reconsume(:bogus_doctype)
          end
          nil
        end

        def doctype_public_double(cp)
          doctype_quoted(cp, 34, :after_doctype_public_id, "quotation mark (\")", "abrupt-doctype-public-identifier", "DOCTYPE public identifier missing closing %s.")
        end

        def doctype_public_single(cp)
          doctype_quoted(cp, 39, :after_doctype_public_id, "apostrophe (')", "abrupt-doctype-public-identifier", "DOCTYPE public identifier missing closing %s.")
        end

        def doctype_quoted(cp, quote, after, closer, code, template)
          case cp
          when quote
            @doctype[:public_id] = @temporary if after == :after_doctype_public_id
            @doctype[:system_id] = @temporary if after == :after_doctype_system_id
            go(after)
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            @temporary << REPLACEMENT.chr(Encoding::UTF_8)
          when 62
            error(code, format(template, closer))
            force_quirks
            if after == :after_doctype_public_id
              @doctype[:public_id] = @temporary
            else
              @doctype[:system_id] = @temporary
            end
            go(:data)
            return emit_doctype
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            @temporary << cp.chr(Encoding::UTF_8)
          end
          nil
        end

        def after_doctype_public_id(cp)
          if space?(cp)
            go(:between_doctype_ids)
          elsif cp == 62
            go(:data)
            return emit_doctype
          elsif cp == 34
            error("missing-whitespace-between-doctype-public-and-system-identifiers", "Missing whitespace between DOCTYPE public and system identifiers.")
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_double)
          elsif cp == 39
            error("missing-whitespace-between-doctype-public-and-system-identifiers", "Missing whitespace between DOCTYPE public and system identifiers.")
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_single)
          elsif cp == EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("missing-quote-before-doctype-system-identifier", "Missing quote before DOCTYPE system identifier.")
            force_quirks
            reconsume(:bogus_doctype)
          end
          nil
        end

        def between_doctype_ids(cp)
          return nil if space?(cp)

          case cp
          when 62
            go(:data)
            return emit_doctype
          when 34
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_double)
          when 39
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_single)
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("missing-quote-before-doctype-system-identifier", "Missing quote before DOCTYPE system identifier.")
            force_quirks
            reconsume(:bogus_doctype)
          end
          nil
        end

        def after_doctype_system(cp)
          if space?(cp)
            go(:before_doctype_system)
          elsif cp == 34
            error("missing-whitespace-after-doctype-system-keyword", "Missing whitespace after 'SYSTEM' keyword.")
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_double)
          elsif cp == 39
            error("missing-whitespace-after-doctype-system-keyword", "Missing whitespace after 'SYSTEM' keyword.")
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_single)
          elsif cp == 62
            error("missing-doctype-system-identifier", "Missing DOCTYPE system identifier.")
            force_quirks
            go(:data)
            return emit_doctype
          elsif cp == EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("missing-quote-before-doctype-system-identifier", "Missing quote before DOCTYPE system identifier.")
            force_quirks
            reconsume(:bogus_doctype)
          end
          nil
        end

        def before_doctype_system(cp)
          return nil if space?(cp)

          case cp
          when 34
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_double)
          when 39
            @temporary = +""
            @doctype[:has_system_id] = true
            go(:doctype_system_single)
          when 62
            error("missing-doctype-system-identifier", "Missing DOCTYPE system identifier.")
            force_quirks
            go(:data)
            return emit_doctype
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("missing-quote-before-doctype-system-identifier", "Missing quote before DOCTYPE system identifier.")
            force_quirks
            reconsume(:bogus_doctype)
          end
          nil
        end

        def doctype_system_double(cp)
          doctype_quoted(cp, 34, :after_doctype_system_id, "quotation mark (\")", "abrupt-doctype-system-identifier", "DOCTYPE system identifier missing closing %s.")
        end

        def doctype_system_single(cp)
          doctype_quoted(cp, 39, :after_doctype_system_id, "apostrophe (')", "abrupt-doctype-system-identifier", "DOCTYPE system identifier missing closing %s.")
        end

        def after_doctype_system_id(cp)
          return nil if space?(cp)

          case cp
          when 62
            go(:data)
            return emit_doctype
          when EOF
            error("eof-in-doctype", "End of input in DOCTYPE.")
            force_quirks
            reconsume(:data)
            return emit_doctype
          else
            error("unexpected-character-after-doctype-system-identifier", "Unexpected character after DOCTYPE system identifier.")
            reconsume(:bogus_doctype)
          end
          nil
        end

        def bogus_doctype(cp)
          case cp
          when 62
            go(:data)
            return emit_doctype
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
          when EOF
            reconsume(:data)
            return emit_doctype
          end
          nil
        end

        def force_quirks
          @doctype[:force_quirks] = true
        end

        def emit_doctype
          token = Token.new(
            type: :doctype,
            name: @doctype[:name].to_s,
            public_id: @doctype[:public_id].to_s,
            system_id: @doctype[:system_id].to_s,
            has_public_id: @doctype[:has_public_id] ? true : false,
            has_system_id: @doctype[:has_system_id] ? true : false,
            force_quirks: @doctype[:force_quirks] ? true : false,
            line: start_line,
            column: start_column,
            byte_offset: start_offset
          )
          @doctype = {}
          finish_token
          token
        end

        def cdata(cp)
          case cp
          when 93
            mark
            go(:cdata_bracket)
          when 0
            error("unexpected-null-character", "Input contains unexpected U+0000.")
            return emit_cdata(REPLACEMENT)
          when EOF
            error("eof-in-cdata", "End of input in CDATA section.")
            @in_cdata = false
            reconsume(:data)
            return emit_eof
          else
            return emit_cdata(cp)
          end
          nil
        end

        def cdata_bracket(cp)
          if cp == 93
            go(:cdata_end)
          else
            reconsume(:cdata)
            return emit_from_mark
          end
          nil
        end

        def cdata_end(cp)
          case cp
          when 93
            token = emit_from_mark
            @resume = nil
            mark
            go(:cdata)
            token
          when 62
            @in_cdata = false
            go(:data)
            nil
          else
            reconsume(:cdata)
            emit_from_mark
          end
        end

        def character_reference(cp)
          if alnum?(cp)
            reconsume(:named_reference)
          elsif cp == 35
            go(:numeric_reference)
          else
            reconsume(@return_state)
            return flush_reference_text
          end
          nil
        end

        def named_reference(_cp)
          suffix = slice(@index, @chars.length)
          match = Entities.match(suffix)
          if match
            length, first, second = match
            matched = suffix.byteslice(0, length)
            @index += length
            nxt = current_cp
            semicolon = matched.end_with?(";")
            if attribute_reference? && !semicolon && (nxt == 61 || alnum?(nxt))
              reconsume(@return_state)
              return flush_reference_text
            end
            unless semicolon
              shown = slice(@mark, @index)
              error("missing-semicolon-after-character-reference", "Missing semicolon after character reference '#{shown}'.", :mark)
            end
            reconsume(@return_state)
            return flush_codepoint(first, second)
          end
          reconsume(:ambiguous_ampersand)
          flush_reference_text
        end

        def ambiguous_ampersand(cp)
          if alnum?(cp)
            return append_or_emit(cp)
          end
          if cp == 59
            shown = slice(@mark, @index + 1)
            error("unknown-named-character-reference", "Unknown named character reference '#{shown}'.", :mark)
          end
          reconsume(@return_state)
          nil
        end

        def numeric_reference(cp)
          @ref_value = 0
          if cp == 120 || cp == 88
            go(:hex_start)
          else
            reconsume(:dec_start)
          end
          nil
        end

        def hex_start(cp)
          if hex?(cp)
            reconsume(:hex_ref)
          else
            shown = slice(@mark, @index)
            error("absence-of-digits-in-numeric-character-reference", "Numeric character reference '#{shown}' does not contain any hexadecimal digits.", :mark)
            reconsume(@return_state)
            return flush_reference_text
          end
          nil
        end

        def dec_start(cp)
          if digit?(cp)
            reconsume(:dec_ref)
          else
            shown = slice(@mark, @index)
            error("absence-of-digits-in-numeric-character-reference", "Numeric character reference '#{shown}' does not contain any digits.", :mark)
            reconsume(@return_state)
            return flush_reference_text
          end
          nil
        end

        def hex_ref(cp)
          if digit?(cp)
            bump_ref(16, cp - 48)
          elsif cp.between?(65, 70)
            bump_ref(16, cp - 55)
          elsif cp.between?(97, 102)
            bump_ref(16, cp - 87)
          elsif cp == 59
            go(:numeric_end)
          else
            missing_semicolon
            reconsume(:numeric_end)
          end
          nil
        end

        def dec_ref(cp)
          if digit?(cp)
            bump_ref(10, cp - 48)
          elsif cp == 59
            go(:numeric_end)
          else
            missing_semicolon
            reconsume(:numeric_end)
          end
          nil
        end

        def bump_ref(base, digit)
          @ref_value = (@ref_value * base) + digit
          @ref_value = MAX_CHAR + 1 if @ref_value > MAX_CHAR
        end

        def hex?(cp)
          digit?(cp) || cp.between?(65, 70) || cp.between?(97, 102)
        end

        def missing_semicolon
          shown = slice(@mark, @index)
          error("missing-semicolon-after-character-reference", "Missing semicolon after character reference '#{shown}'.", :mark)
        end

        def numeric_end(_cp)
          value = normalize_numeric(@ref_value)
          reconsume(@return_state)
          flush_codepoint(value, nil)
        end

        def normalize_numeric(value)
          shown = slice(@mark, @index)
          if value == 0
            error("null-character-reference", "Numeric character reference '#{shown}' references U+0000.", :mark)
            return REPLACEMENT
          end
          if value > MAX_CHAR
            error("character-reference-outside-unicode-range", "Numeric character reference '#{shown}' references a code point that is outside the valid Unicode range.", :mark)
            return REPLACEMENT
          end
          if surrogate?(value)
            error("surrogate-character-reference", format("Numeric character reference '%s' references surrogate U+%4X.", shown, value), :mark)
            return REPLACEMENT
          end
          if noncharacter?(value)
            error("noncharacter-character-reference", format("Numeric character reference '%s' references noncharacter U+%04X.", shown, value), :mark)
          elsif c1_control?(value) || value == 0x0D || (control?(value) && !space?(value))
            error("control-character-reference", format("Numeric character reference '%s' references prohibited control code point U+%04X.", shown, value), :mark)
            return WINDOWS1252.fetch(value, value)
          end
          value
        end

        WINDOWS1252 = {
          0x80 => 0x20AC, 0x82 => 0x201A, 0x83 => 0x0192, 0x84 => 0x201E,
          0x85 => 0x2026, 0x86 => 0x2020, 0x87 => 0x2021, 0x88 => 0x02C6,
          0x89 => 0x2030, 0x8A => 0x0160, 0x8B => 0x2039, 0x8C => 0x0152,
          0x8E => 0x017D, 0x91 => 0x2018, 0x92 => 0x2019, 0x93 => 0x201C,
          0x94 => 0x201D, 0x95 => 0x2022, 0x96 => 0x2013, 0x97 => 0x2014,
          0x98 => 0x02DC, 0x99 => 0x2122, 0x9A => 0x0161, 0x9B => 0x203A,
          0x9C => 0x0153, 0x9E => 0x017E, 0x9F => 0x0178
        }.freeze

        def surrogate?(value)
          value.between?(0xD800, 0xDFFF)
        end

        def noncharacter?(value)
          value.between?(0xFDD0, 0xFDEF) || (value & 0xFFFE) == 0xFFFE
        end

        def attribute_reference?
          @return_state == :attr_double || @return_state == :attr_single || @return_state == :attr_unquoted
        end

        def flush_reference_text
          if attribute_reference?
            text = slice(@mark, @index)
            @buffer << text
            nil
          else
            emit_from_mark
          end
        end

        def flush_codepoint(first, second)
          if attribute_reference?
            @buffer << first.chr(Encoding::UTF_8)
            @buffer << second.chr(Encoding::UTF_8) if second
            nil
          else
            @buffered = second
            emit_char(first)
          end
        end

        def append_or_emit(cp)
          if attribute_reference?
            @buffer << cp.chr(Encoding::UTF_8)
            nil
          else
            emit_char(cp)
          end
        end
      end
    end
  end
end
