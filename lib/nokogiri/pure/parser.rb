# frozen_string_literal: true

require "strscan"

module Nokogiri
  module Pure
    # XML parser for the pure Ruby backend.
    class Parser
      RECOVER = 1
      NAME = /[\p{L}_:][\p{L}\p{N}_:.\-]*/.freeze
      UNQUOTED = /[^\s>\/]*/
      QUOTED_DQ = /[^"&]+/
      QUOTED_SQ = /[^'&]+/
      AMP_START = /[#A-Za-z_:]/
      EMPTY_SCOPE = [].freeze
      # Quote-aware tag. The match stops at the tag's ">", including one
      # that sits inside a quoted attribute value.
      FLAT_TAG = /<(?:[^>"']|"[^"]*"|'[^']*')*>/.freeze
      P_END_MESSAGE = 'The element type "p" must be terminated by the matching end-tag "</p>".'.freeze
      P_END_ERROR = [P_END_MESSAGE, 0, 0, nil, false].freeze

      def self.parse(document, string, options)
        new(document, string, options).parse_document
        document
      end

      # Return unparented nodes parsed from a fragment string.
      def self.parse_fragment(document, string, context, options)
        holder = XML::DocumentFragment.allocate
        State.attach(
          holder,
          type: XML::Node::DOCUMENT_FRAG_NODE,
          name: "#document-fragment",
          document: document,
        )
        new(document, string, options, root: holder, context: context).parse_document
        holder.pure.children.dup.each(&:unlink)
      end

      def initialize(document, string, options, root: nil, context: nil)
        @document = document
        @html = document.respond_to?(:html?) && document.html?
        @root = root || document
        @context = context
        @options = options.to_i
        source = string.to_s.dup
        if source.encoding == Encoding::UTF_8 || source.encoding == Encoding::US_ASCII
          source.delete_prefix!("\uFEFF")
        elsif source.bytesize >= 3 && source.getbyte(0) == 0xEF && source.getbyte(1) == 0xBB && source.getbyte(2) == 0xBF
          source = source.byteslice(3..) || +""
          source.force_encoding(Encoding::UTF_8)
        end
        source = source.dup.force_encoding(Encoding::UTF_8).scrub unless source.valid_encoding?
        @scanner = StringScanner.new(source)
        @line = 1
        @column = 1
        @stack = []
        inherited = inherited_scopes(context)
        @scopes = [inherited]
        # Prefix => namespace for ancestors. The open element's own
        # definitions are consulted before this map.
        @ns_map = {}
        @ns_stack = []
        inherited.each { |ns| @ns_map[ns.prefix] ||= ns }
      end

      def parse_document
        # A declaration is recognized only at the first character.
        fatals_before = @document.errors.count(&:fatal?)
        if @scanner.string.start_with?("<?xml") && @scanner.charpos.zero?
          read_xml_declaration
        end
        parse_loop
        if @stack.any? && @document.errors.count(&:fatal?) == fatals_before
          element = @stack.last
          error("Premature end of data in tag #{element.name} line #{element.line}")
        end
        @stack.clear
        ensure_html_tree
        if strict? && @root.document? && @root.pure.children.none?(&:element?) && @scanner.string.strip.empty?
          error("Start tag expected, '<' not found")
        end
        ensure_html_dtd if @root.document?
        record_validity_errors if @root.document? && (@options & XML::ParseOptions::DTDVALID) != 0
      end

      def ensure_html_dtd
        return unless html_document?
        return if @document.internal_subset

        dtd = build_dtd(
          "html",
          "-//W3C//DTD HTML 4.0 Transitional//EN",
          "http://www.w3.org/TR/REC-html40/loose.dtd",
        )
        dtd.pure.parent = @document
        @document.pure.children.unshift(dtd)
      end

      private

      def parse_loop
        # A "<!" starts a comment, a doctype, or CDATA. Those stay on the
        # general loop for XML. Plain XML is elements, text, and end tags.
        # A document with only elements and text is stored as flat records.
        # HTML can use the same table when every construct has a record.
        saved_pos = @scanner.pos
        saved_line = @line
        saved_column = @column
        tree = @html ? try_flat_html : try_flat_tree
        if tree
          @document.instance_variable_set(:@flat, tree)
          tree.attach_top
          @scanner.terminate
          flush_flat_errors
          return
        end
        @flat_errors = nil
        @scanner.pos = saved_pos
        @line = saved_line
        @column = saved_column
        if !@html && !@scanner.string.include?("<!")
          parse_loop_xml
        else
          parse_loop_general
        end
      end

      # Build a flat table or return nil so the general reader can run.
      # Nil means the document has a construct this path does not handle.
      # This path must not report errors and must not attach nodes.
      def try_flat_tree
        return nil if @html || !@root.document?

        string = @scanner.string
        origin = @scanner.pos
        return nil if string.byteindex("<!", origin) || string.byteindex("<?", origin)

        @flat_nl = flat_newline_table(string)
        @flat_nl_i = 0
        tree = FlatTree.new(@document, string)
        @fn_map = {}
        @fn_stack = []
        stack = []
        pos = origin
        limit = string.bytesize
        newlines = @flat_nl
        newline_at = 0
        newline_count = newlines.length
        sc = StringScanner.new(string)
        while pos < limit
          unless string.getbyte(pos) == 60
            nxt = string.byteindex("<", pos) || limit
            length = nxt - pos
            if length > 0
              if stack.empty?
                index = pos
                while index < nxt
                  byte = string.getbyte(index)
                  return nil unless byte == 32 || byte == 9 || byte == 10 || byte == 13

                  index += 1
                end
              else
                amp = string.byteindex("&", pos)
                newline_at += 1 while newline_at < newline_count && newlines[newline_at] < nxt
                if amp && amp < nxt && !plain_entities?(string, pos, length)
                  return nil
                end

                tree.add_text_range(stack.last, pos, length, newline_at + 1)
              end
            end
            pos = nxt
            next
          end

          # The tag end is found in C. A search for the next quote from here
          # would read the rest of the document on every bare tag.
          sc.pos = pos
          return nil unless sc.skip(FLAT_TAG)

          gt = sc.pos - 1
          byte = string.getbyte(pos + 1)
          if byte == 47
            name_off = pos + 2
            ending = true
          else
            return nil unless byte && byte < 128 && name_start_byte?(byte)

            name_off = pos + 1
            ending = false
          end
          index = name_off
          local_delta = 0
          while index < gt
            byte = string.getbyte(index)
            unless byte && (
              (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte == 58 ||
              (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
            )
              break
            end

            local_delta = index - name_off + 1 if byte == 58 && local_delta.zero?
            index += 1
          end
          return nil if index == name_off

          name_len = index - name_off
          self_closing = false
          attributed = false
          while index < gt
            byte = string.getbyte(index)
            if byte == 47
              self_closing = true
            elsif byte != 32 && byte != 9 && byte != 10 && byte != 13
              attributed = true
              break
            end
            index += 1
          end
          if attributed
            return nil if ending
            return nil unless flat_add_tag(tree, string, pos, gt, stack)

            pos = gt + 1
            next
          end

          if ending
            return nil if self_closing || stack.empty? || !tree.raw_eq?(stack.last, name_off, name_len)

            stack.pop
            previous = @fn_stack.pop
            @fn_map = previous if previous
          else
            ns_id = -1
            if local_delta.zero?
              found = @fn_map[nil]
              ns_id = found if found
            else
              found = flat_lookup(tree, string.byteslice(name_off, local_delta - 1))
              if found.nil?
                local_delta = 0
              else
                ns_id = found
              end
            end
            newline_at += 1 while newline_at < newline_count && newlines[newline_at] < pos
            parent = stack.last
            parent = -1 if parent.nil?
            element = tree.add_element(parent, name_off, name_len, local_delta, ns_id, newline_at + 1, EMPTY_SCOPE)
            unless self_closing
              stack << element
              @fn_stack << nil
            end
          end
          pos = gt + 1
        end
        return nil unless stack.empty?

        tree
      end

      # HTML records stay on the flat table until a reader asks for a node.
      # A construct this path does not represent returns nil. The caller then
      # runs the general reader. Errors are buffered so a failed scan adds none.
      def try_flat_html
        return nil unless @html && @root.document?

        string = @scanner.string
        limit = string.bytesize
        @flat_errors = []
        @flat_nl = flat_newline_table(string)
        @flat_nl_i = 0
        tree = FlatTree.new(@document, string)
        tree.mark_html
        stack = []
        pos = @scanner.pos
        while pos < limit
          unless html_markup_at?(string, pos, limit)
            nxt = pos
            nxt = string.byteindex("<", pos) || limit if string.getbyte(pos) != 60
            while nxt < limit && !html_markup_at?(string, nxt, limit)
              found = string.byteindex("<", nxt + 1)
              nxt = found || limit
            end
            if nxt > pos
              parent = stack.empty? ? -1 : stack[-1]
              return nil unless add_html_text(tree, string, pos, nxt, parent)
            end
            pos = nxt
            next
          end

          byte = string.getbyte(pos + 1)
          if byte == 33
            if string.getbyte(pos + 2) == 45 && string.getbyte(pos + 3) == 45
              pos = read_html_comment(tree, string, pos, limit, stack)
              return nil if pos.nil?
            elsif string.byteslice(pos, 9) == "<!DOCTYPE"
              pos = read_html_doctype(tree, string, pos, limit, stack)
              return nil if pos.nil?
            else
              return nil
            end
          elsif byte == 63
            return nil
          elsif byte == 47
            pos = read_html_end(tree, string, pos, limit, stack)
            return nil if pos.nil?
          else
            pos = read_html_start(tree, string, pos, limit, stack)
            return nil if pos.nil?
          end
        end
        finish_html_flat(tree, string, limit, stack)
        tree
      end

      def finish_html_flat(tree, string, limit, stack)
        return if stack.empty? || flat_fatal?

        index = stack[-1]
        line, column = flat_location(string, limit)
        name = tree.folded_name(index)
        @flat_errors << ["Premature end of data in tag #{name} line #{tree.line_of(index)}", line, column, 3, true]
      end

      def flat_fatal?
        list = @flat_errors
        index = 0
        length = list.length
        while index < length
          return true if list[index][3] == 3

          index += 1
        end
        false
      end

      def flush_flat_errors
        list = @flat_errors
        @flat_errors = nil
        return unless list

        index = 0
        length = list.length
        while index < length
          message, line, column, level, location = list[index]
          if location
            @line = line
            @column = column
          end
          error(message, level: level, location: location)
          index += 1
        end
      end

      def add_html_text(tree, string, from, to, parent)
        if parent < 0
          return add_html_root_text(string, from, to)
        end

        line = flat_line(to)
        span = from
        pos = from
        split = false
        names = nil
        while (amp = string.byteindex("&", pos)) && amp < to
          kind = entity_kind(string, amp, to)
          if kind.nil?
            pos = amp + 1
            next
          end
          if kind[0] == :keep
            pos = kind[1] + 1
            next
          end

          name = string.byteslice(kind[1], kind[2])
          return nil if noent? || lookup_entity(name)

          split = true
          tree.add_text_range(parent, span, amp - span, line) if amp > span
          tree.add_entity_ref(parent, kind[1], kind[2])
          span = kind[3] + 1
          pos = span
          names ||= []
          names << name
        end
        if split
          tree.add_text_range(parent, span, to - span, line) if span < to
          column = flat_column(string, to)
          names.each do |name|
            @flat_errors << ["Entity '#{name}' not defined", line, column, 3, true]
          end
        elsif to > from
          tree.add_text_range(parent, from, to - from, line)
        end
        true
      end

      def add_html_root_text(string, from, to)
        index = from
        while index < to
          byte = string.getbyte(index)
          return nil if byte >= 128
          unless byte == 32 || byte == 9 || byte == 10 || byte == 13
            line, column = flat_location(string, to)
            @flat_errors << ["Start tag expected, '<' not found", line, column, 3, true]
            return true
          end
          index += 1
        end
        true
      end

      def read_html_comment(tree, string, pos, limit, stack)
        close = string.byteindex("-->", pos + 4)
        return limit if close.nil?

        parent = stack.empty? ? -1 : stack[-1]
        body = close - (pos + 4)
        tree.add_comment(parent, pos + 4, body, nil) if body >= 0
        close + 3
      end

      def read_html_doctype(tree, string, pos, limit, stack)
        index = skip_tag_space(string, pos + 9, limit)
        return nil if index.nil?

        name_off = index
        while index < limit
          byte = string.getbyte(index)
          break unless byte && byte < 128 && name_byte?(byte)

          index += 1
        end
        name = string.byteslice(name_off, index - name_off)
        index = skip_tag_space(string, index, limit)
        return nil if index.nil?

        external_id = nil
        system_id = nil
        if keyword_at?(string, index, limit, "PUBLIC")
          index = skip_tag_space(string, index + 6, limit)
          return nil if index.nil?

          external_id, index = read_html_id(string, index, limit)
          return nil if index.nil?

          index = skip_tag_space(string, index, limit)
          return nil if index.nil?

          quote = string.getbyte(index)
          if quote == 34 || quote == 39
            system_id, index = read_html_id(string, index, limit)
            return nil if index.nil?

            index = skip_tag_space(string, index, limit)
            return nil if index.nil?
          end
        elsif keyword_at?(string, index, limit, "SYSTEM")
          index = skip_tag_space(string, index + 6, limit)
          return nil if index.nil?

          system_id, index = read_html_id(string, index, limit)
          return nil if index.nil?

          index = skip_tag_space(string, index, limit)
          return nil if index.nil?
        end
        return nil if index >= limit || string.getbyte(index) == 91
        return nil unless string.getbyte(index) == 62

        parent = stack.empty? ? -1 : stack[-1]
        tree.add_dtd(parent, name, external_id, system_id)
        index + 1
      end

      def read_html_id(string, index, limit)
        quote = string.getbyte(index)
        return [nil, nil] unless quote == 34 || quote == 39

        close = string.byteindex(quote == 34 ? "\"" : "'", index + 1)
        return [nil, nil] unless close && close < limit
        return [nil, nil] if string.byteindex("&", index + 1)&.between?(index + 1, close - 1)

        [string.byteslice(index + 1, close - index - 1), close + 1]
      end

      def keyword_at?(string, index, limit, word)
        length = word.bytesize
        return false if index + length > limit
        return false unless string.getbyte(index) == word.getbyte(0)
        return false unless string.byteslice(index, length) == word

        nxt = string.getbyte(index + length)
        nxt.nil? || nxt == 32 || nxt == 9 || nxt == 10 || nxt == 13 || nxt == 62
      end

      def read_html_end(tree, string, pos, limit, stack)
        index = skip_tag_space(string, pos + 2, limit)
        return nil if index.nil? || index >= limit

        byte = string.getbyte(index)
        return nil unless byte && byte < 128 && ((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122))

        name_off = index
        index += 1
        while index < limit
          byte = string.getbyte(index)
          break unless byte && byte < 128 && name_byte?(byte)

          index += 1
        end
        name_len = index - name_off
        index = skip_tag_space(string, index, limit)
        return nil if index.nil? || index >= limit || string.getbyte(index) != 62

        if html_stack_has?(tree, stack, string, name_off, name_len)
          finish_html_end(tree, string, name_off, name_len, index + 1, stack)
        elsif html_p_or_br?(string, name_off, name_len)
          parent = stack.empty? ? -1 : stack[-1]
          tree.add_element(parent, name_off, name_len, 0, -1, nil, EMPTY_SCOPE)
          index + 1
        else
          note_html_mismatch(tree, string, name_off, name_len, index + 1, stack)
          index + 1
        end
      end

      def finish_html_end(tree, string, name_off, name_len, next_pos, stack)
        unless stack.empty? || tree.html_name_eq?(stack[-1], string, name_off, name_len)
          if stack.empty?
            note_html_mismatch(tree, string, name_off, name_len, next_pos, stack)
          elsif tree.p_open?(stack[-1])
            @flat_errors << P_END_ERROR
          else
            name = tree.folded_name(stack[-1])
            @flat_errors << [%(The element type "#{name}" must be terminated by the matching end-tag "</#{name}>."), 0, 0, nil, false]
          end
          stack.pop while stack.any? && !tree.html_name_eq?(stack[-1], string, name_off, name_len)
        end
        stack.pop if stack.any? && tree.html_name_eq?(stack[-1], string, name_off, name_len)
        next_pos
      end

      def note_html_mismatch(tree, string, name_off, name_len, next_pos, stack)
        if stack.empty?
          name = string.byteslice(name_off, name_len)
          name = name.downcase if name.match?(/[A-Z]/)
          line, column = flat_location(string, next_pos)
          @flat_errors << ["Opening and ending tag mismatch: #{name}", line, column, 3, true]
        elsif tree.p_open?(stack[-1])
          @flat_errors << P_END_ERROR
        else
          name = tree.folded_name(stack[-1])
          @flat_errors << [%(The element type "#{name}" must be terminated by the matching end-tag "</#{name}>."), 0, 0, nil, false]
        end
      end

      def read_html_start(tree, string, pos, limit, stack)
        index = pos + 1
        name_off = index
        index += 1
        while index < limit
          byte = string.getbyte(index)
          break unless byte && byte < 128 && name_byte?(byte)

          index += 1
        end
        return nil if index == name_off

        name_len = index - name_off
        parent = stack.empty? ? -1 : stack[-1]
        element = tree.add_element(parent, name_off, name_len, 0, -1, flat_line(pos), EMPTY_SCOPE)
        closed = false
        self_closing = false
        while index < limit
          index = skip_tag_space(string, index, limit)
          return nil if index.nil?
          break if index >= limit

          byte = string.getbyte(index)
          if byte == 62
            closed = true
            index += 1
            break
          end
          if byte == 47
            return nil unless index + 1 < limit && string.getbyte(index + 1) == 62

            self_closing = true
            closed = true
            index += 2
            break
          end
          return nil if byte >= 128 || !name_start_byte?(byte)

          attr_off = index
          index += 1
          while index < limit
            byte = string.getbyte(index)
            break unless byte && byte < 128 && name_byte?(byte)

            index += 1
          end
          attr_len = index - attr_off
          index = skip_tag_space(string, index, limit)
          return nil if index.nil?

          if index < limit && string.getbyte(index) == 61
            index += 1
            index = skip_tag_space(string, index, limit)
            return nil if index.nil? || index >= limit

            quote = string.getbyte(index)
            if quote == 34 || quote == 39
              close = string.byteindex(quote == 34 ? "\"" : "'", index + 1)
              return nil unless close && close < limit

              value_off = index + 1
              value_len = close - value_off
              tree.add_html_attr(element, attr_off, attr_len, value_off, value_len, 1)
              if value_len.positive?
                amp = string.byteindex("&", value_off)
                return nil unless amp.nil? || amp >= value_off + value_len || note_quoted_entities(string, value_off, value_off + value_len)
              end
              index = close + 1
            else
              value_off = index
              while index < limit
                byte = string.getbyte(index)
                break if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 62 || byte == 47

                index += 1
              end
              tree.add_html_attr(element, attr_off, attr_len, value_off, index - value_off, 0)
            end
          else
            tree.add_html_attr(element, attr_off, attr_len, -1, 0, 0)
          end
        end
        return nil unless closed

        stack << element unless self_closing || void_at?(string, name_off, name_len)
        index
      end

      def skip_tag_space(string, index, limit)
        while index < limit
          byte = string.getbyte(index)
          if byte == 32 || byte == 9 || byte == 10 || byte == 13
            index += 1
          elsif byte == 11 || byte == 12 || (byte && byte >= 128)
            return nil
          else
            return index
          end
        end
        index
      end

      def html_markup_at?(string, pos, limit)
        return false if pos < 0 || pos >= limit

        byte = string.getbyte(pos)
        return false unless byte == 60

        nxt = string.getbyte(pos + 1)
        return false unless nxt
        return true if nxt == 33 || nxt == 63
        if nxt == 47
          third = string.getbyte(pos + 2)
          return false unless third

          return (third >= 65 && third <= 90) || (third >= 97 && third <= 122)
        end
        (nxt >= 65 && nxt <= 90) || (nxt >= 97 && nxt <= 122)
      end

      def html_stack_has?(tree, stack, string, off, len)
        index = stack.length
        while index > 0
          index -= 1
          return true if tree.html_name_eq?(stack[index], string, off, len)
        end
        false
      end

      def html_p_or_br?(string, off, len)
        if len == 1
          byte = string.getbyte(off)
          byte == 112 || byte == 80
        elsif len == 2
          first = string.getbyte(off)
          second = string.getbyte(off + 1)
          first += 32 if first >= 65 && first <= 90
          second += 32 if second >= 65 && second <= 90
          first == 98 && second == 114
        else
          false
        end
      end

      def void_at?(string, off, len)
        list = self.class.void_name_groups[len]
        return false unless list

        index = 0
        while index < list.length
          return true if same_ascii_name?(string, off, list[index])

          index += 1
        end
        false
      end

      def same_ascii_name?(string, off, name)
        index = 0
        length = name.bytesize
        while index < length
          byte = string.getbyte(off + index)
          byte += 32 if byte >= 65 && byte <= 90
          return false if byte != name.getbyte(index)

          index += 1
        end
        true
      end

      def note_quoted_entities(string, from, to)
        pos = from
        while (amp = string.byteindex("&", pos)) && amp < to
          kind = entity_kind(string, amp, to)
          if kind.nil?
            pos = amp + 1
            next
          end
          if kind[0] == :keep
            pos = kind[1] + 1
            next
          end

          name = string.byteslice(kind[1], kind[2])
          return nil if noent? || lookup_entity(name)

          line, column = flat_location(string, kind[3] + 1)
          @flat_errors << ["Entity '#{name}' not defined", line, column, 3, true]
          pos = kind[3] + 1
        end
        true
      end

      # :keep means a predefined or numeric reference that stays in the text.
      # :bad is an unknown name. nil is a bare "&".
      def entity_kind(string, amp, limit)
        nxt = amp + 1
        return nil if nxt >= limit

        byte = string.getbyte(nxt)
        if byte == 35
          semi = numeric_semi(string, nxt, limit)
          return nil unless semi

          return [:keep, semi]
        end
        return nil unless byte && ((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122))

        index = nxt + 1
        while index < limit
          byte = string.getbyte(index)
          break unless entity_name_byte?(byte)

          index += 1
        end
        return nil if index >= limit || string.getbyte(index) != 59

        if predefined_at?(string, nxt, index - nxt)
          [:keep, index]
        else
          [:bad, nxt, index - nxt, index]
        end
      end

      def numeric_semi(string, hash_pos, limit)
        index = hash_pos + 1
        return nil if index >= limit

        byte = string.getbyte(index)
        if byte == 120 || byte == 88
          index += 1
          start = index
          while index < limit && hex_byte?(string.getbyte(index))
            index += 1
          end
          return nil if index == start
        else
          start = index
          while index < limit
            byte = string.getbyte(index)
            break unless byte >= 48 && byte <= 57

            index += 1
          end
          return nil if index == start
        end
        return nil if index >= limit || string.getbyte(index) != 59

        index
      end

      def entity_name_byte?(byte)
        return false unless byte
        return true if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        return true if byte >= 48 && byte <= 57

        byte == 45 || byte == 46
      end

      def hex_byte?(byte)
        return false unless byte
        return true if byte >= 48 && byte <= 57
        return true if byte >= 65 && byte <= 70

        byte >= 97 && byte <= 102
      end

      def predefined_at?(string, off, len)
        case len
        when 2
          first = string.getbyte(off)
          second = string.getbyte(off + 1)
          (first == 108 && second == 116) || (first == 103 && second == 116)
        when 3
          string.getbyte(off) == 97 && string.getbyte(off + 1) == 109 && string.getbyte(off + 2) == 112
        when 4
          first = string.getbyte(off)
          if first == 113
            string.getbyte(off + 1) == 117 && string.getbyte(off + 2) == 111 && string.getbyte(off + 3) == 116
          elsif first == 97
            string.getbyte(off + 1) == 112 && string.getbyte(off + 2) == 111 && string.getbyte(off + 3) == 115
          else
            false
          end
        else
          false
        end
      end

      def flat_location(string, pos)
        [flat_line(pos), flat_column(string, pos)]
      end

      def flat_column(string, pos)
        index = @flat_nl_i
        last = index.positive? ? @flat_nl[index - 1] : -1
        start = last + 1
        string.byteslice(start, pos - start).length + 1
      end

      def flat_newline_table(string)
        table = []
        pos = 0
        while (found = string.byteindex("\n", pos))
          table << found
          pos = found + 1
        end
        table
      end

      def flat_line(byte_pos)
        table = @flat_nl
        index = @flat_nl_i
        length = table.length
        index += 1 while index < length && table[index] < byte_pos
        @flat_nl_i = index
        index + 1
      end

      def flat_tag_end(string, pos, limit)
        index = pos + 1
        while index < limit
          byte = string.getbyte(index)
          if byte == 34 || byte == 39
            close = string.byteindex(byte == 34 ? "\"" : "'", index + 1)
            return nil unless close

            index = close + 1
          elsif byte == 62
            return index
          else
            index += 1
          end
        end
        nil
      end

      def flat_add_text(tree, string, pos, nxt, stack)
        length = nxt - pos
        return true if length.zero?

        if stack.empty?
          index = pos
          while index < nxt
            byte = string.getbyte(index)
            return nil unless byte == 32 || byte == 9 || byte == 10 || byte == 13

            index += 1
          end
          return true
        end

        amp = string.byteindex("&", pos)
        if amp && amp < nxt
          decoded = decode_fast_attr(string.byteslice(pos, length))
          return nil if decoded.nil?

          tree.add_text(stack.last, decoded, flat_line(nxt))
        else
          tree.add_text_range(stack.last, pos, length, flat_line(nxt))
        end
        true
      end

      def flat_add_tag(tree, string, pos, gt, stack)
        if string.getbyte(pos + 1) == 47
          return flat_end_tag(tree, string, pos, gt, stack)
        end

        byte = string.getbyte(pos + 1)
        return nil unless byte && byte < 128 && name_start_byte?(byte)

        index = pos + 1
        index += 1 while index < gt && (byte = string.getbyte(index)) && byte < 128 && name_byte?(byte)
        return nil if index == pos + 1

        name_off = pos + 1
        name_len = index - name_off
        local_delta = 0
        cursor = name_off
        while cursor < index
          if string.getbyte(cursor) == 58
            local_delta = cursor - name_off + 1
            break
          end
          cursor += 1
        end
        self_closing = string.getbyte(gt - 1) == 47
        attr_stop = self_closing ? gt - 1 : gt
        attrs = flat_read_attrs(string, index, attr_stop)
        return nil unless attrs

        declared = []
        plain = []
        attrs.each do |attr_name, value|
          if attr_name == "xmlns"
            declared << tree.define_ns(nil, value)
          elsif attr_name.start_with?("xmlns:")
            prefix = attr_name.split(":", 2).last
            return nil if prefix.empty?

            declared << tree.define_ns(prefix, value)
          else
            plain << [attr_name, value]
          end
        end

        old_map = nil
        unless declared.empty?
          old_map = @fn_map
          @fn_map = old_map.dup
          declared.each { |id| @fn_map[tree.prefix_of(id)] = id }
        end

        ns_id = -1
        if local_delta.zero?
          found = @fn_map[nil]
          ns_id = found if found
        else
          prefix = string.byteslice(name_off, local_delta - 1)
          found = flat_lookup(tree, prefix)
          if found.nil?
            local_delta = 0
          else
            ns_id = found
          end
        end

        parent = stack.empty? ? -1 : stack.last
        element = tree.add_element(parent, name_off, name_len, local_delta, ns_id, flat_line(pos), declared)
        lang = nil
        plain.each do |attr_name, value|
          attr_prefix, attr_local = split_name(attr_name)
          if attr_prefix
            found = flat_lookup(tree, attr_prefix)
            if found
              tree.add_attr(element, attr_local, found, value)
              lang = value if attr_prefix == "xml" && attr_local == "lang"
            else
              tree.add_attr(element, attr_local, -1, value)
            end
          else
            tree.add_attr(element, attr_name, -1, value)
          end
        end
        tree.set_lang(element, lang) if lang

        if self_closing
          @fn_map = old_map if old_map
        else
          stack << element
          @fn_stack << old_map
        end
        true
      end

      def flat_lookup(tree, prefix)
        found = @fn_map[prefix]
        return found unless found.nil?
        return tree.xml_ns_id(@document) if prefix == "xml"

        nil
      end

      def flat_end_tag(tree, string, pos, gt, stack)
        index = pos + 2
        while index < gt
          byte = string.getbyte(index)
          break unless byte == 32 || byte == 9 || byte == 10 || byte == 13

          index += 1
        end
        return nil if index >= gt

        byte = string.getbyte(index)
        return nil unless byte && byte < 128 && name_start_byte?(byte)

        start = index
        index += 1
        while index < gt
          byte = string.getbyte(index)
          break unless byte && byte < 128 && name_byte?(byte)

          index += 1
        end
        name_end = index
        while index < gt
          byte = string.getbyte(index)
          return nil unless byte == 32 || byte == 9 || byte == 10 || byte == 13

          index += 1
        end

        return nil if stack.empty? || !tree.raw_eq?(stack.last, start, name_end - start)

        stack.pop
        previous = @fn_stack.pop
        @fn_map = previous if previous
        true
      end

      def flat_read_attrs(string, index, stop)
        attrs = []
        while index < stop
          while index < stop
            byte = string.getbyte(index)
            break unless byte == 32 || byte == 9 || byte == 10 || byte == 13

            index += 1
          end
          break if index >= stop

          byte = string.getbyte(index)
          return nil if byte == 47
          return nil unless byte && byte < 128 && name_start_byte?(byte)

          start = index
          index += 1
          while index < stop
            byte = string.getbyte(index)
            break unless byte && (
              (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte == 58 ||
              (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
            )

            index += 1
          end
          attr_name = string.byteslice(start, index - start)
          while index < stop
            byte = string.getbyte(index)
            break unless byte == 32 || byte == 9 || byte == 10 || byte == 13

            index += 1
          end
          return nil unless string.getbyte(index) == 61

          index += 1
          while index < stop
            byte = string.getbyte(index)
            break unless byte == 32 || byte == 9 || byte == 10 || byte == 13

            index += 1
          end
          quote = string.getbyte(index)
          return nil unless quote == 34 || quote == 39

          index += 1
          value_at = index
          close = string.byteindex(quote == 34 ? "\"" : "'", index)
          return nil unless close && close < stop

          raw = string.byteslice(value_at, close - value_at)
          value = raw.byteindex("&") ? decode_fast_attr(raw) : raw
          return nil if value.nil?

          attrs << [attr_name, value]
          index = close + 1
        end
        attrs
      end

      # True when every "&" in the range is a predefined entity or a
      # character reference. A custom entity makes the flat path give up.
      def plain_entities?(string, from, length)
        limit = from + length
        amp = string.byteindex("&", from)
        while amp && amp < limit
          semi = string.byteindex(";", amp + 1)
          return false unless semi && semi < limit

          name = string.byteslice(amp + 1, semi - amp - 1)
          if name.getbyte(0) == 35
            return false unless decode_char_ref(name)
          else
            return false unless Entities::PREDEFINED.key?(name)
          end
          break if semi + 1 >= limit

          amp = string.byteindex("&", semi + 1)
        end
        true
      end

      def parse_loop_general
        scanner = @scanner
        until scanner.eos?
          # "<" is one ASCII byte, including inside a UTF-8 document.
          if scanner.string.getbyte(scanner.pos) == 60
            if html_document? && !html_markup?
              append_text(take_char.to_s)
            else
              parse_markup
            end
          else
            append_text(read_until_markup)
          end
        end
      end

      # One pass over a document that has no "<!" markup. Start tags are
      # scanned in place. A tag with an entity or a non-ASCII byte uses the
      # general reader from the "<".
      def parse_loop_xml
        string = @scanner.string
        limit = string.bytesize
        pos = @scanner.pos
        while pos < limit
          if string.getbyte(pos) != 60
            # byteindex, not index. index counts characters and loops
            # when the offset is a byte position after a multibyte character.
            found = string.byteindex("<", pos)
            found = limit if found.nil?
            chunk = string.byteslice(pos, found - pos)
            account_text(chunk)
            append_text_xml(chunk)
            pos = found
            next
          end

          saved_line = @line
          saved_column = @column
          nxt = string.getbyte(pos + 1)
          if nxt == 63
            @scanner.pos = pos
            parse_markup
            pos = @scanner.pos
          elsif nxt == 47
            pos = read_end_tag_fast(string, pos, limit, saved_line, saved_column)
          elsif nxt && nxt < 128 && name_start_byte?(nxt)
            pos = read_start_tag_fast(string, pos, limit, saved_line, saved_column)
          else
            @scanner.pos = pos
            parse_markup
            pos = @scanner.pos
          end
        end
        @scanner.pos = pos
      end

      def read_start_tag_fast(string, pos, limit, saved_line, saved_column)
        cursor = pos + 1
        quote = nil
        plain = true
        while cursor < limit
          byte = string.getbyte(cursor)
          if byte >= 128
            plain = false
          end
          if quote
            quote = nil if byte == quote
          elsif byte == 34 || byte == 39
            quote = byte
          elsif byte == 38
            plain = false
          elsif byte == 62 && quote.nil?
            break
          end
          cursor += 1
        end
        unless plain && cursor < limit && quote.nil?
          return read_start_tag_slow(pos, saved_line, saved_column)
        end

        stop = cursor
        self_closing = string.getbyte(stop - 1) == 47
        index = pos + 1
        qname, index = take_ascii_name(string, index, stop)
        if qname.nil? || qname.empty?
          return read_start_tag_slow(pos, saved_line, saved_column)
        end

        attributes = {}
        while index < stop
          index = pass_ascii_space(string, index, stop)
          break if index >= stop

          byte = string.getbyte(index)
          break if byte == 47 || byte == 62

          attr_name, index = take_ascii_name(string, index, stop)
          return read_start_tag_slow(pos, saved_line, saved_column) if attr_name.nil? || attr_name.empty?

          index = pass_ascii_space(string, index, stop)
          return read_start_tag_slow(pos, saved_line, saved_column) unless string.getbyte(index) == 61

          index += 1
          index = pass_ascii_space(string, index, stop)
          quote_byte = string.getbyte(index)
          return read_start_tag_slow(pos, saved_line, saved_column) unless quote_byte == 34 || quote_byte == 39

          index += 1
          value_at = index
          index += 1 while index < stop && string.getbyte(index) != quote_byte
          return read_start_tag_slow(pos, saved_line, saved_column) if index >= stop

          raw = string.byteslice(value_at, index - value_at)
          value = decode_fast_attr(raw)
          return read_start_tag_slow(pos, saved_line, saved_column) if value.nil?

          attributes[attr_name] = value
          index += 1
        end

        account_text(string.byteslice(pos, stop - pos + 1))
        element = make_node(XML::Element, XML::Node::ELEMENT_NODE, qname, nil, saved_line)
        apply_namespaces(element, qname, attributes)
        append_node(element)
        push_open_element(element) unless self_closing
        stop + 1
      end

      # An unknown entity returns nil so the general reader can report it.
      def decode_fast_attr(value)
        amp = value.byteindex("&")
        return value unless amp

        out = +""
        limit = value.bytesize
        i = 0
        while amp
          out << value.byteslice(i, amp - i) if amp > i
          semi = value.byteindex(";", amp + 1)
          return nil unless semi

          name = value.byteslice(amp + 1, semi - amp - 1)
          if (char = Entities::PREDEFINED[name])
            out << char
          elsif name.getbyte(0) == 35
            char = decode_char_ref(name)
            return nil unless char

            out << char
          else
            return nil
          end
          i = semi + 1
          break if i >= limit

          amp = value.byteindex("&", i)
        end
        out << value.byteslice(i, limit - i) if i < limit
        out
      end

      def decode_char_ref(name)
        hex = name.getbyte(1) == 120 || name.getbyte(1) == 88
        digits = name.byteslice(hex ? 2 : 1, name.bytesize)
        return nil if digits.nil? || digits.empty?

        code = 0
        digits.each_byte do |byte|
          if byte >= 48 && byte <= 57
            code = (hex ? code * 16 : code * 10) + (byte - 48)
          elsif hex && byte >= 65 && byte <= 70
            code = code * 16 + (byte - 55)
          elsif hex && byte >= 97 && byte <= 102
            code = code * 16 + (byte - 87)
          else
            return nil
          end
          return nil if code > 0x10FFFF
        end
        Entities.codepoint_char(code)
      end

      def read_start_tag_slow(pos, saved_line, saved_column)
        @line = saved_line
        @column = saved_column
        @scanner.pos = pos
        read_start_tag
        @scanner.pos
      end

      def take_ascii_name(string, index, stop)
        index = pass_ascii_space(string, index, stop)
        return [nil, index] if index >= stop

        byte = string.getbyte(index)
        return [nil, index] unless byte && byte < 128 && name_start_byte?(byte)

        start = index
        index += 1
        while index < stop
          byte = string.getbyte(index)
          break unless byte < 128 && name_byte?(byte)

          index += 1
        end
        [string.byteslice(start, index - start), index]
      end

      def pass_ascii_space(string, index, stop)
        while index < stop
          byte = string.getbyte(index)
          break unless byte == 32 || byte == 9 || byte == 10 || byte == 13

          index += 1
        end
        index
      end

      def html_markup?
        string = @scanner.string
        pos = @scanner.pos
        byte = string.getbyte(pos + 1)
        return false unless byte
        return true if byte == 33 || byte == 63

        if byte == 47
          next_byte = string.getbyte(pos + 2)
          return false unless next_byte

          return (next_byte >= 65 && next_byte <= 90) || (next_byte >= 97 && next_byte <= 122)
        end

        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
      end

      def parse_markup
        string = @scanner.string
        pos = @scanner.pos
        byte = string.getbyte(pos + 1)
        if byte == 33
          second = string.getbyte(pos + 2)
          if second == 45 && string.getbyte(pos + 3) == 45
            append_node(read_comment)
          elsif second == 91 && string.byteslice(pos, 9) == "<![CDATA["
            append_node(read_cdata)
          elsif second == 68 && string.byteslice(pos, 9) == "<!DOCTYPE"
            append_node(read_doctype)
          else
            error("Unsupported markup declaration")
            skip_through(">")
          end
        elsif byte == 63
          append_node(read_pi)
        elsif byte == 47
          read_end_tag
        else
          read_start_tag
        end
      end

      def read_xml_declaration
        advance("<?xml")
        attributes = read_attributes
        skip_space
        advance("?>")
        @document.pure.version = attributes["version"] if attributes["version"]
        @document.encoding = attributes["encoding"] if attributes["encoding"]
      end

      def read_start_tag
        advance("<")
        line = @line
        qname = read_name
        qname.downcase! if html_document? && !qname.empty?
        if qname.empty?
          error("StartTag: invalid element name")
          return
        end
        attributes = read_attributes
        skip_space
        self_closing = false
        string = @scanner.string
        mark = @scanner.pos
        if string.getbyte(mark) == 47 && string.getbyte(mark + 1) == 62
          advance("/>")
          self_closing = true
        else
          expect(">")
        end

        element = make_node(XML::Element, XML::Node::ELEMENT_NODE, qname, nil, line)
        apply_namespaces(element, qname, attributes)
        append_node(element)
        push_open_element(element) unless self_closing || void_html?(element.name)
      end

      def push_open_element(element)
        @stack << element
        defs = element.pure.namespace_definitions
        if defs.empty?
          @scopes << EMPTY_SCOPE
          @ns_stack << nil
        else
          @scopes << defs.dup
          @ns_stack << @ns_map
          @ns_map = @ns_map.dup
          defs.each { |ns| @ns_map[ns.prefix] = ns }
        end
      end

      def pop_open_element
        @stack.pop
        @scopes.pop if @scopes.length > 1
        previous = @ns_stack.pop
        @ns_map = previous if previous
      end

      def read_end_tag
        advance("</")
        qname = read_name
        skip_space
        expect(">")
        name = local_name(qname)
        name.downcase! if html_document? && !name.empty?
        if html_document? && @stack.none? { |node| node.name == name }
          if name == "p" || name == "br"
            append_node(make_node(XML::Element, XML::Node::ELEMENT_NODE, name))
          else
            open = @stack.last
            if open
              error(
                %(The element type "#{open.name}" must be terminated by the matching end-tag "</#{open.name}>".),
                level: nil,
                location: false,
              )
            else
              error("Opening and ending tag mismatch: #{name}")
            end
          end
          return
        end
        finish_end_tag(name)
      end

      def finish_end_tag(name)
        if @stack.empty? || @stack.last.name != name
          open = @stack.last
          if open
            error(
              %(The element type "#{open.name}" must be terminated by the matching end-tag "</#{open.name}>".),
              level: nil,
              location: false,
            )
          else
            error("Opening and ending tag mismatch: #{name}")
          end
          pop_open_element while @stack.any? && @stack.last.name != name
        end
        return unless @stack.last&.name == name

        pop_open_element
      end

      def read_end_tag_fast(string, pos, limit, saved_line, saved_column)
        index = pass_ascii_space(string, pos + 2, limit)
        byte = index < limit ? string.getbyte(index) : nil
        return read_end_tag_slow(pos, saved_line, saved_column) unless byte && byte < 128 && name_start_byte?(byte)

        start = index
        index += 1
        while index < limit
          byte = string.getbyte(index)
          break unless byte && byte < 128 && name_byte?(byte)

          index += 1
        end
        name_end = index
        index = pass_ascii_space(string, index, limit)
        return read_end_tag_slow(pos, saved_line, saved_column) unless index < limit && string.getbyte(index) == 62

        account_text(string.byteslice(pos, index - pos + 1))
        finish_end_tag(local_name(string.byteslice(start, name_end - start)))
        index + 1
      end

      def read_end_tag_slow(pos, saved_line, saved_column)
        @line = saved_line
        @column = saved_column
        @scanner.pos = pos
        read_end_tag
        @scanner.pos
      end

      def read_comment
        advance("<!--")
        body = +""
        closed = false
        until @scanner.eos?
          if @scanner.check(/-->/)
            advance("-->")
            closed = true
            break
          end
          body << take_char
        end
        return if html_document? && !closed

        XML::Comment.new(@document, body)
      end

      def read_cdata
        advance("<![CDATA[")
        body = +""
        until @scanner.eos?
          if @scanner.check(/\]\]>/)
            advance("]]>")
            break
          end
          body << take_char
        end
        XML::CDATA.new(@document, body)
      end

      def read_pi
        advance("<?")
        target = read_name
        error("XML declaration allowed only at the start of the document") if target == "xml"
        error("xmlParsePI : no target name") if target.empty?
        skip_space
        body = +""
        until @scanner.eos?
          if @scanner.check(/\?>/)
            advance("?>")
            break
          end
          body << take_char
        end
        return if target.empty?

        XML::ProcessingInstruction.new(@document, target, body)
      end

      def read_doctype
        advance("<!DOCTYPE")
        skip_space
        name = read_name
        skip_space
        external_id = nil
        system_id = nil
        if @scanner.check(/PUBLIC/)
          advance("PUBLIC")
          skip_space
          external_id = read_quoted
          skip_space
          system_id = read_quoted if @scanner.check(/['"]/)
        elsif @scanner.check(/SYSTEM/)
          advance("SYSTEM")
          skip_space
          system_id = read_quoted
        end
        skip_space
        dtd = build_dtd(name, external_id, system_id)
        parse_internal_subset(dtd) if @scanner.check(/\[/)
        if load_external_subset? && system_id
          external = build_dtd(name, external_id, system_id)
          @document.pure.external_subset = external
          load_external_declarations(external, system_id, document_base)
        end
        skip_space
        expect(">")
        dtd
      end

      def build_dtd(name, external_id, system_id)
        dtd = XML::DTD.allocate
        State.attach(
          dtd,
          type: XML::Node::DTD_NODE,
          name: name,
          document: @document,
          external_id: external_id,
          system_id: system_id,
        )
        dtd
      end

      def load_external_subset?
        (@options & (XML::ParseOptions::DTDLOAD | XML::ParseOptions::DTDVALID)) != 0
      end

      def parse_internal_subset(dtd)
        advance("[")
        parse_declarations(dtd, document_base)
        advance("]") if @scanner.check(/\]/)
      end

      def parse_declarations(dtd, base)
        until @scanner.eos? || @scanner.check(/\]/)
          skip_space
          break if @scanner.eos? || @scanner.check(/\]/)

          if @scanner.check(/<!--/)
            read_comment
          elsif @scanner.check(/<\?/)
            read_pi
          elsif @scanner.check(/<!ENTITY/)
            read_entity_declaration(dtd, base)
          elsif @scanner.check(/<!ELEMENT/)
            read_element_declaration(dtd)
          elsif @scanner.check(/<!ATTLIST/)
            read_attlist_declaration(dtd)
          elsif @scanner.check(/<!NOTATION/)
            read_notation_declaration(dtd)
          elsif @scanner.check(/<!/)
            skip_declaration
          else
            break
          end
        end
      end

      def load_external_declarations(dtd, system_id, base)
        path = resolve_system_path(system_id, base)
        return unless path

        saved = [@scanner, @line, @column]
        @scanner = StringScanner.new(File.read(path))
        @line = 1
        @column = 1
        parse_declarations(dtd, path)
      ensure
        @scanner, @line, @column = saved if saved
      end

      def read_entity_declaration(dtd, base)
        advance("<!ENTITY")
        skip_space
        parameter = false
        if @scanner.check(/%/)
          advance("%")
          parameter = true
          skip_space
        end
        name = read_name
        skip_space
        if @scanner.check(/PUBLIC/)
          advance("PUBLIC")
          skip_space
          external_id = read_quoted
          skip_space
          system_id = read_quoted if @scanner.check(/['"]/)
          ndata = read_ndata
          add_entity(dtd, name, XML::EntityDecl::EXTERNAL_GENERAL_UNPARSED, external_id, system_id, nil, base) if !parameter && ndata
          add_entity(dtd, name, XML::EntityDecl::EXTERNAL_GENERAL_PARSED, external_id, system_id, nil, base) if !parameter && ndata.nil?
        elsif @scanner.check(/SYSTEM/)
          advance("SYSTEM")
          skip_space
          system_id = read_quoted
          ndata = read_ndata
          type = ndata ? XML::EntityDecl::EXTERNAL_GENERAL_UNPARSED : XML::EntityDecl::EXTERNAL_GENERAL_PARSED
          add_entity(dtd, name, type, nil, system_id, nil, base) unless parameter
        else
          value = read_quoted
          add_entity(dtd, name, XML::EntityDecl::INTERNAL_GENERAL, nil, nil, value, base) unless parameter
        end
        skip_space
        expect(">")
      end

      def read_ndata
        skip_space
        return unless @scanner.check(/NDATA/)

        advance("NDATA")
        skip_space
        read_name
      end

      def add_entity(dtd, name, type, external_id, system_id, value, base)
        return if name.empty? || dtd.entities.key?(name)

        node = XML::EntityDecl.allocate
        State.attach(
          node,
          type: XML::Node::ENTITY_DECL,
          name: name,
          document: @document,
          content: value,
          external_id: external_id,
          system_id: system_id,
        )
        node.instance_variable_set(:@entity_type, type)
        node.instance_variable_set(:@entity_base, base)
        dtd.add_child_node(node)
      end

      def read_element_declaration(dtd)
        advance("<!ELEMENT")
        skip_space
        name = read_name
        skip_space
        model = read_model
        node = XML::ElementDecl.allocate
        State.attach(
          node,
          type: XML::Node::ELEMENT_DECL,
          name: name,
          document: @document,
        )
        node.instance_variable_set(:@element_type, element_type_code(model))
        node.instance_variable_set(:@content_model, model)
        node.instance_variable_set(:@element_content, build_element_content(model))
        (dtd.instance_variable_get(:@attrs_for) || {})[name]&.each do |attr|
          node.pure.attributes << attr
        end
        dtd.add_child_node(node)
        skip_space
        expect(">")
      end

      def read_model
        return "" if @scanner.eos?

        if @scanner.check(/EMPTY|ANY/)
          token = @scanner.check(/EMPTY|ANY/)
          advance(token)
          return token
        end

        model = +""
        depth = 0
        until @scanner.eos?
          break if depth.zero? && @scanner.check(/>/)

          char = take_char
          model << char
          depth += 1 if char == "("
          depth -= 1 if char == ")"
        end
        model.strip
      end

      def build_element_content(model)
        return if model.nil? || model.empty? || model == "EMPTY" || model == "ANY"

        ContentModel.parse(@document, model)
      end

      def element_type_code(model)
        case model
        when "EMPTY" then 1
        when "ANY" then 2
        else
          model.include?("#PCDATA") ? 3 : 4
        end
      end

      def read_attlist_declaration(dtd)
        advance("<!ATTLIST")
        skip_space
        element_name = read_name
        skip_space
        until @scanner.eos? || @scanner.check(/>/)
          attr_name = read_name
          break if attr_name.empty?

          skip_space
          if @scanner.check(/\(/)
            enumeration = read_enumeration
            attr_type = "ENUMERATION"
          else
            attr_type = read_name
            enumeration = []
          end
          skip_space
          default = read_attr_default
          add_attribute_decl(dtd, element_name, attr_name, attr_type, default, enumeration)
          skip_space
        end
        expect(">")
      end

      def read_enumeration
        advance("(")
        values = []
        until @scanner.eos?
          skip_space
          break if @scanner.check(/\)/)

          token = @scanner.check(/[^)|]+/)
          values << token.strip if token
          advance(token) if token
          skip_space
          advance("|") if @scanner.check(/\|/)
        end
        advance(")") if @scanner.check(/\)/)
        values
      end

      def read_attr_default
        if @scanner.check(/#/)
          advance("#")
          token = read_name
          skip_space
          return read_quoted if @scanner.check(/['"]/)

          return nil if token == "IMPLIED" || token == "REQUIRED"

          return nil
        end
        read_quoted if @scanner.check(/['"]/)
      end

      def add_attribute_decl(dtd, element_name, name, attr_type, default, enumeration)
        node = XML::AttributeDecl.allocate
        State.attach(
          node,
          type: XML::Node::ATTRIBUTE_DECL,
          name: name,
          document: @document,
          content: default,
        )
        node.instance_variable_set(:@attribute_type, attr_type)
        node.instance_variable_set(:@default_value, default)
        node.instance_variable_set(:@enumeration, enumeration)
        node.instance_variable_set(:@owner_element, element_name)
        dtd.add_child_node(node)
        attrs = dtd.instance_variable_get(:@attrs_for) || {}
        (attrs[element_name] ||= []) << node
        dtd.instance_variable_set(:@attrs_for, attrs)
        element = dtd.pure.children.find { |child| child.node_type == XML::Node::ELEMENT_DECL && child.name == element_name }
        element.pure.attributes << node if element
      end

      def read_notation_declaration(dtd)
        advance("<!NOTATION")
        skip_space
        name = read_name
        skip_space
        public_id = nil
        system_id = nil
        if @scanner.check(/PUBLIC/)
          advance("PUBLIC")
          skip_space
          public_id = read_quoted
          skip_space
          system_id = read_quoted if @scanner.check(/['"]/)
        elsif @scanner.check(/SYSTEM/)
          advance("SYSTEM")
          skip_space
          system_id = read_quoted
        end
        skip_space
        expect(">")
        notations = dtd.instance_variable_get(:@notations) || {}
        notations[name] ||= XML::Notation.new(name, public_id, system_id)
        dtd.instance_variable_set(:@notations, notations)
      end

      def skip_declaration
        advance("<!")
        quote = nil
        until @scanner.eos?
          char = take_char
          break if char.nil?
          if quote
            quote = nil if char == quote
            next
          end
          case char
          when "'", '"'
            quote = char
          when ">"
            break
          end
        end
      end

      def html_document?
        @html
      end

      def self.void_html_names
        @void_html_names ||= begin
          names = {}
          HTML4::ElementDescription::DefaultDescriptions.each do |name, desc|
            names[name] = true if desc.empty
          end
          names.freeze
        end
      end

      def void_html?(name)
        return false unless @html

        self.class.void_html_names[name]
      end

      def self.void_name_groups
        @void_name_groups ||= begin
          groups = {}
          void_html_names.each_key do |name|
            (groups[name.bytesize] ||= []) << name
          end
          groups
        end
      end

      def ensure_html_tree
        return unless html_document? && @root.document?

        elements = @document.pure.children.select(&:element?)
        return if elements.any? { |node| node.name.casecmp?("html") }

        html = XML::Element.new("html", @document)
        body = XML::Element.new("body", @document)
        movable = @document.pure.children.reject { |node| node.node_type == XML::Node::DTD_NODE }
        movable.each do |node|
          node.unlink
          node.pure.parent = body
          body.pure.children << node
        end
        body.pure.parent = html
        html.pure.children << body
        html.pure.parent = @document
        @document.pure.children << html
      end

      def apply_namespaces(element, qname, attributes)
        unless html_document?
          attributes.each do |attr_name, value|
            if attr_name == "xmlns"
              element.add_namespace_definition(nil, value)
            elsif attr_name.start_with?("xmlns:")
              element.add_namespace_definition(attr_name.split(":", 2).last, value)
            end
          end

          prefix, local = split_name(qname)
          if prefix
            ns = find_namespace(prefix, element)
            if ns
              element.pure.name = local
              element.pure.namespace = ns
            end
          else
            default_ns = find_namespace(nil, element)
            element.pure.namespace = default_ns if default_ns
          end
        end

        attributes.each do |attr_name, value|
          next if !html_document? && (attr_name == "xmlns" || attr_name.start_with?("xmlns:"))

          if html_document?
            attr = make_node(XML::Attr, XML::Node::ATTRIBUTE_NODE, attr_name.downcase, value&.to_s)
            attr.pure.parent = element
            element.pure.attributes << attr
            next
          end

          attr_prefix, attr_local = split_name(attr_name)
          attr = make_node(
            XML::Attr,
            XML::Node::ATTRIBUTE_NODE,
            attr_prefix ? attr_local : attr_name,
            value&.to_s,
          )
          attr.pure.parent = element
          if attr_prefix
            ns = find_namespace(attr_prefix, element)
            attr.pure.namespace = ns if ns
            element.pure.lang = value if attr_prefix == "xml" && attr_local == "lang"
          end
          element.pure.attributes << attr
        end
      end

      def find_namespace(prefix, element)
        element.pure.namespace_definitions.each do |ns|
          return ns if ns.prefix == prefix
        end
        found = @ns_map[prefix]
        return found if found
        return @document.xml_namespace if prefix == "xml"

        nil
      end

      def inherited_scopes(context)
        return [] unless context.respond_to?(:namespace_scopes)

        context.namespace_scopes
      end

      def append_node(node)
        return if node.nil?

        state = node.instance_variable_get(:@pure)
        parent = @stack.last || @root
        return parent.add_child_node(node) unless state

        text_node = XML::Node::TEXT_NODE
        return if @root.document? && state.type == text_node && node.blank? && @stack.empty?

        # Parser nodes are new. Skip the cycle check and the unlink.
        if state.parent || !state.children.empty?
          parent.add_child_node(node)
          return
        end

        parent_state = parent.instance_variable_get(:@pure)
        if state.type == text_node
          last = parent_state.children.last
          if last
            last_state = last.instance_variable_get(:@pure)
            if last_state&.type == text_node
              extra = state.content.to_s
              current = last_state.content
              if current.is_a?(String) && !current.frozen?
                current << extra
              else
                last_state.content = current.to_s + extra
              end
              return
            end
          end
        end

        state.parent = parent
        state.document = parent_state.document
        parent_state.children << node
        node.decorate!
        # apply_namespaces already bound this element's namespaces. A second
        # adopt_namespaces walk repeats that search for every element.
      end

      def make_node(klass, type, name, content = nil, line = nil)
        node = klass.allocate
        Pure::State.fast_attach(node, type, name, @document, content, line)
        node
      end

      def append_text_xml(text)
        return if text.empty?

        # A document drops whitespace at the root. A fragment keeps that text.
        if @stack.empty? && @root.document?
          error("Start tag expected, '<' not found") unless text.match?(/\A\s*\z/)
          return
        end
        return append_text(text) if text.include?("&")

        parent = @stack.last || @root
        parent_state = parent.instance_variable_get(:@pure)
        last = parent_state.children.last
        if last
          last_state = last.instance_variable_get(:@pure)
          if last_state&.type == XML::Node::TEXT_NODE
            current = last_state.content
            if current.is_a?(String) && !current.frozen?
              current << text
            else
              last_state.content = current.to_s + text
            end
            return
          end
        end

        node = make_node(XML::Text, XML::Node::TEXT_NODE, "text", text, @line)
        state = node.instance_variable_get(:@pure)
        state.parent = parent
        state.document = parent_state.document
        parent_state.children << node
      end

      def append_text(text)
        return if text.empty?
        if @root.document? && @stack.empty?
          error("Start tag expected, '<' not found") unless text.match?(/\A\s*\z/)
          return
        end

        unless text.include?("&")
          append_node(make_node(XML::Text, XML::Node::TEXT_NODE, "text", text, @line))
          return
        end

        split_text_and_entities(text).each do |piece|
          node = piece.is_a?(XML::Node) ? piece : make_node(XML::Text, XML::Node::TEXT_NODE, "text", piece, @line)
          append_node(node)
        end
      end

      def split_text_and_entities(text)
        pieces = []
        buffer = +""
        scanner = StringScanner.new(text)
        until scanner.eos?
          if (literal = scanner.scan(/[^&]+/))
            buffer << literal
          elsif (ref = scanner.scan(/&(?:#\d+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9.-]*);/))
            name = ref[1..-2]
            if name.start_with?("#") || Entities::PREDEFINED.key?(name)
              buffer << Entities.decode_predefined(ref)
            elsif (entity = lookup_entity(name))
              pieces << buffer unless buffer.empty?
              buffer = +""
              pieces.concat(entity_reference_nodes(name, entity))
            else
              pieces << buffer unless buffer.empty?
              buffer = +""
              error("Entity '#{name}' not defined")
              pieces << XML::EntityReference.new(@document, name) unless noent?
            end
          else
            buffer << scanner.getch
          end
        end
        pieces << buffer unless buffer.empty?
        pieces
      end

      def read_until_markup
        string = @scanner.string
        pos = @scanner.pos
        found = string.byteindex("<", pos)
        unless found
          rest = string.byteslice(pos..) || +""
          @scanner.terminate
          account_text(rest)
          return rest
        end

        @scanner.pos = found
        return "" if found == pos

        text = string.byteslice(pos, found - pos)
        account_text(text)
        text
      end

      def read_attributes
        attributes = {}
        loop do
          skip_space
          byte = @scanner.string.getbyte(@scanner.pos)
          break if @scanner.eos? || byte == 62 || byte == 47

          name = read_name
          break if name.empty?

          skip_space
          if html_document? && @scanner.string.getbyte(@scanner.pos) != 61
            attributes[name] = ""
            next
          end
          expect("=")
          skip_space
          attributes[name] = read_attribute_value
        end
        attributes
      end

      def read_attribute_value
        return read_quoted if @scanner.check(/['"]/)
        return read_unquoted if html_document?

        read_quoted
      end

      def read_unquoted
        value = @scanner.scan(UNQUOTED) || ""
        account_text(value)
        value
      end

      def read_quoted
        quote = take_char
        unless quote == '"' || quote == "'"
          error("AttValue: \" or ' expected")
          return ""
        end
        pattern = quote == '"' ? QUOTED_DQ : QUOTED_SQ
        value = +""
        until @scanner.eos?
          run = @scanner.scan(pattern)
          if run
            value << run
            account_text(run)
            next
          end

          char = take_char
          break if char == quote

          if char == "&" && (!html_document? || @scanner.check(AMP_START))
            ref = +char
            until @scanner.eos?
              next_char = take_char
              ref << next_char
              break if next_char == ";"
            end
            value << decode_attribute_entity(ref)
          else
            value << char
          end
        end
        value
      end

      def decode_attribute_entity(ref)
        name = ref[1..-2]
        if name.nil?
          ref
        elsif name.start_with?("#") || Entities::PREDEFINED.key?(name)
          Entities.decode_predefined(ref)
        elsif (entity = lookup_entity(name))
          entity_text(entity)
        else
          error("Entity '#{name}' not defined")
          ref
        end
      end

      def noent?
        @options & XML::ParseOptions::NOENT != 0
      end

      def document_base
        url = @document.url
        return if url.nil? || url.empty?

        url
      end

      def lookup_entity(name)
        subset = @document.internal_subset
        found = subset.entities[name] if subset
        return found if found

        subset = @document.external_subset
        subset.entities[name] if subset
      end

      def entity_reference_nodes(name, entity)
        if entity_external?(entity)
          if noent? && entity.entity_type == XML::EntityDecl::EXTERNAL_GENERAL_PARSED
            nodes_from_entity_text(load_entity_source(entity).to_s)
          elsif noent?
            []
          else
            [XML::EntityReference.new(@document, name)]
          end
        elsif noent?
          nodes_from_entity_text(entity.content.to_s)
        else
          [XML::EntityReference.new(@document, name)]
        end
      end

      def entity_external?(entity)
        entity.entity_type != XML::EntityDecl::INTERNAL_GENERAL
      end

      def entity_text(entity)
        if entity_external?(entity)
          return "" unless noent? && entity.entity_type == XML::EntityDecl::EXTERNAL_GENERAL_PARSED

          load_entity_source(entity).to_s
        else
          entity.content.to_s
        end
      end

      def nodes_from_entity_text(text)
        return [] if text.empty?

        open = open_entities
        return [] if open.include?(text)

        open << text
        stripped = text.sub(/\A\s*<\?xml[^?]*\?>/, "")
        Parser.parse_fragment(@document, stripped, @stack.last, @options)
      ensure
        open&.pop
      end

      def open_entities
        list = @document.instance_variable_get(:@pure_open_entities)
        return list if list

        @document.instance_variable_set(:@pure_open_entities, [])
      end

      def load_entity_source(entity)
        resolve_system_path(entity.system_id, entity.instance_variable_get(:@entity_base))&.then { |path| File.read(path) }
      end

      def resolve_system_path(system_id, base)
        return if system_id.nil? || system_id.empty?
        return if system_id.match?(/\A[a-z][a-z0-9+.-]*:/i)

        if system_id.start_with?("/")
          return system_id if File.file?(system_id)

          return
        end
        return unless base

        directory = File.directory?(base) ? base : File.dirname(base)
        candidate = File.expand_path(system_id, directory)
        candidate if File.file?(candidate)
      end

      def record_validity_errors
        declared = {}
        [@document.internal_subset, @document.external_subset].compact.each do |subset|
          subset.elements.each_key { |name| declared[name] = true }
        end
        seen_attributes = {}
        each_validity_element(@document) do |element|
          known = declared[element.name]
          error("No declaration for element #{element.name}", level: 2) unless known
          element.pure.attributes.each do |attr|
            next if known
            next if seen_attributes[attr.name]

            seen_attributes[attr.name] = true
            error("No declaration for attribute #{attr.name} of element #{element.name}", level: 2)
          end
        end
      end

      def each_validity_element(node, &block)
        node.pure.children.each do |child|
          if child.element?
            yield child
            each_validity_element(child, &block)
          elsif child.node_type == XML::Node::ENTITY_REF_NODE
            entity = lookup_entity(child.name)
            next unless entity && !entity_external?(entity)

            nodes_from_entity_text(entity.content.to_s).each do |replacement|
              next unless replacement.element?

              yield replacement
              each_validity_element(replacement, &block)
            end
          end
        end
      end

      def read_name
        skip_space
        string = @scanner.string
        pos = @scanner.pos
        return "" if pos >= string.bytesize

        byte = string.getbyte(pos)
        return read_name_unicode if byte >= 128
        return "" unless name_start_byte?(byte)

        start = pos
        pos += 1
        limit = string.bytesize
        while pos < limit
          byte = string.getbyte(pos)
          if byte >= 128
            @scanner.pos = start
            return read_name_unicode
          end
          break unless name_byte?(byte)

          pos += 1
        end
        @scanner.pos = pos
        match = string.byteslice(start, pos - start)
        account_text(match)
        match
      end

      def read_name_unicode
        match = @scanner.check(NAME)
        return "" unless match

        advance(match)
        match
      end

      def name_start_byte?(byte)
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte == 58
      end

      def name_byte?(byte)
        name_start_byte?(byte) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
      end

      def split_name(qname)
        return [nil, qname] unless qname.include?(":")

        qname.split(":", 2)
      end

      def local_name(qname)
        _prefix, local = split_name(qname)
        local
      end

      def skip_space
        string = @scanner.string
        pos = @scanner.pos
        limit = string.bytesize
        start = pos
        while pos < limit
          byte = string.getbyte(pos)
          if byte == 11 || byte == 12 || byte >= 128
            @scanner.pos = start
            spaces = @scanner.scan(/\s+/)
            account_text(spaces) if spaces
            return
          end
          break unless byte == 32 || byte == 9 || byte == 10 || byte == 13

          pos += 1
        end
        return if pos == start

        @scanner.pos = pos
        account_text(string.byteslice(start, pos - start))
      end

      def skip_through(token)
        chunk = @scanner.scan_until(token_pattern(token))
        unless chunk
          rest = @scanner.rest
          @scanner.terminate
          account_text(rest)
          return
        end

        account_text(chunk)
      end

      def expect(token)
        return if advance(token)

        error("expected #{token.inspect}")
      end

      def advance(token)
        return false unless @scanner.peek(token.length) == token

        @scanner.pos += token.bytesize
        account_text(token)
        true
      end

      def token_pattern(token)
        @token_patterns ||= {}
        @token_patterns[token] ||= Regexp.new(Regexp.escape(token))
      end

      def account_text(string)
        return if string.nil? || string.empty?

        newlines = string.count("\n")
        if newlines.zero?
          @column += string.length
        else
          @line += newlines
          @column = string.length - string.rindex("\n")
        end
      end

      def take_char
        char = @scanner.getch
        return nil unless char

        if char == "\n"
          @line += 1
          @column = 1
        else
          @column += 1
        end
        char
      end

      def strict?
        @options & RECOVER == 0
      end

      def error(message, level: 3, location: true)
        syntax = XML::SyntaxError.new(message)
        if location
          syntax.instance_variable_set(:@line, @line)
          syntax.instance_variable_set(:@column, @column)
        end
        syntax.instance_variable_set(:@level, level)
        @document.errors << syntax
      end
    end

    # Binary content-model tree for an ELEMENT declaration.
    class ContentModel
      def self.parse(document, model)
        new(document, model).parse_particle
      end

      def initialize(document, model)
        @document = document
        @scanner = StringScanner.new(model.strip)
      end

      def parse_particle
        skip_space
        if @scanner.scan(/\(/)
          node = parse_group
          skip_space
          @scanner.scan(/\)/)
          node.instance_variable_set(:@occur, occurrence)
          node
        elsif @scanner.scan(/#PCDATA/)
          content_node(XML::ElementContent::PCDATA, "#PCDATA", nil, occurrence)
        else
          token = @scanner.scan(/[A-Za-z_:][\w:.-]*/)
          prefix, local = split_name(token.to_s)
          content_node(XML::ElementContent::ELEMENT, local, prefix, occurrence)
        end
      end

      private

      def parse_group
        first = parse_particle
        skip_space
        if @scanner.check(/,/)
          chain(first, XML::ElementContent::SEQ, /,/)
        elsif @scanner.check(/\|/)
          chain(first, XML::ElementContent::OR, /\|/)
        else
          first
        end
      end

      def chain(first, type, separator)
        items = [first]
        while @scanner.scan(separator)
          items << parse_particle
          skip_space
        end
        items.reverse.reduce do |right, left|
          node = content_node(type, nil, nil, XML::ElementContent::ONCE)
          node.instance_variable_set(:@c1, left)
          node.instance_variable_set(:@c2, right)
          node
        end
      end

      def content_node(type, name, prefix, occur)
        node = XML::ElementContent.allocate
        node.instance_variable_set(:@document, @document)
        node.instance_variable_set(:@type, type)
        node.instance_variable_set(:@name, name)
        node.instance_variable_set(:@prefix, prefix)
        node.instance_variable_set(:@occur, occur)
        node
      end

      def occurrence
        skip_space
        case @scanner.scan(/[?*+]/)
        when "?" then XML::ElementContent::OPT
        when "*" then XML::ElementContent::MULT
        when "+" then XML::ElementContent::PLUS
        else XML::ElementContent::ONCE
        end
      end

      def split_name(token)
        return [nil, token] unless token.include?(":")

        prefix, local = token.split(":", 2)
        [prefix, local]
      end

      def skip_space
        @scanner.skip(/\s+/)
      end
    end
  end
end
