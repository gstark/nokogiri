# frozen_string_literal: true

module Nokogiri
  module Pure
    # Tree construction rules of the libxml2 HTML parser before v2.14.
    #
    # The tables and the rules come from HTMLparser.c in libxml2 2.13
    # (Copyright (C) 1998-2012 Daniel Veillard, MIT license).
    #
    # The rules keep a stack of open element names. The parser that
    # includes this module keeps its own stack of nodes. It must call
    # html_tree_push and html_tree_pop when it changes that stack, and
    # it must define three hooks:
    #
    # - html_open_implied(name) adds an implied element and pushes it.
    # - html_close_top pops the current element.
    # - html_tree_error(message, offset) reports an error.
    module HTML4Tree
      # A new tag (key) closes each open tag in its list.
      START_CLOSE = {
        "a" => %w[a head],
        "abbr" => %w[head],
        "acronym" => %w[head],
        "address" => %w[head p ul],
        "b" => %w[head],
        "bdo" => %w[head],
        "big" => %w[head],
        "blockquote" => %w[head p],
        "body" => %w[head link p style title],
        "br" => %w[head],
        "caption" => %w[p],
        "center" => %w[b font head i p],
        "cite" => %w[head],
        "code" => %w[head],
        "col" => %w[caption col p],
        "colgroup" => %w[caption col colgroup p],
        "dd" => %w[address dir dt head listing menu p pre xmp],
        "dfn" => %w[head],
        "dir" => %w[head p],
        "div" => %w[head p],
        "dl" => %w[address dir dt head listing menu p pre xmp],
        "dt" => %w[address dd dir head listing menu p pre xmp],
        "em" => %w[head],
        "fieldset" => %w[a h1 h2 h3 h4 h5 h6 head legend listing p pre xmp],
        "font" => %w[head],
        "form" => %w[address dir dl form h1 h2 h3 h4 h5 h6 head hr listing menu ol p pre ul xmp],
        "frameset" => %w[head link p style title],
        "h1" => %w[head p],
        "h2" => %w[head p],
        "h3" => %w[head p],
        "h4" => %w[head p],
        "h5" => %w[head p],
        "h6" => %w[head p],
        "head" => %w[p],
        "hr" => %w[head p],
        "i" => %w[head],
        "iframe" => %w[head],
        "img" => %w[head],
        "kbd" => %w[head],
        "li" => %w[address dl h1 h2 h3 h4 h5 h6 head li listing p pre xmp],
        "listing" => %w[head p],
        "map" => %w[head],
        "menu" => %w[head p ul],
        "noscript" => %w[script],
        "ol" => %w[head p],
        "optgroup" => %w[option],
        "option" => %w[option],
        "p" => %w[b big h1 h2 h3 h4 h5 h6 head i p s small strike tt u],
        "pre" => %w[head p ul],
        "q" => %w[head],
        "s" => %w[head],
        "samp" => %w[head],
        "small" => %w[head],
        "span" => %w[head],
        "strike" => %w[head],
        "strong" => %w[head],
        "sub" => %w[head],
        "sup" => %w[head],
        "table" => %w[a h1 h2 h3 h4 h5 h6 head listing p pre xmp],
        "tbody" => %w[caption col colgroup p tbody td tfoot th thead tr],
        "td" => %w[a b font i p span td th u],
        "tfoot" => %w[caption col colgroup p tbody td th thead tr],
        "th" => %w[a b font i p span td th u],
        "thead" => %w[caption col colgroup],
        "title" => %w[p],
        "tr" => %w[caption col colgroup p td th tr],
        "tt" => %w[head],
        "u" => %w[head],
        "ul" => %w[address dir head listing menu p pre xmp],
        "var" => %w[head],
        "xmp" => %w[head p]
      }.transform_values { |names| names.to_h { |name| [name, true] }.freeze }.freeze

      # An end tag closes open elements only up to this priority.
      END_PRIORITY = {
        "div" => 150,
        "td" => 160,
        "th" => 160,
        "tr" => 170,
        "thead" => 180,
        "tbody" => 180,
        "tfoot" => 180,
        "table" => 190,
        "head" => 200,
        "body" => 200,
        "html" => 220
      }.freeze
      DEFAULT_PRIORITY = 100

      # An end tag that closes one of these reports a mismatch.
      END_TAG_EXPECTED = %w[b big center em font i s small strike strong sub sup tt u]
        .to_h { |name| [name, true] }.freeze

      HEAD_NAMES = %w[script style meta link title base].to_h { |name| [name, true] }.freeze
      FRAME_NAMES = %w[noframes frame frameset].to_h { |name| [name, true] }.freeze
      TOP_NAMES = %w[html head body].to_h { |name| [name, true] }.freeze

      # Level values from libxml2. They never go down.
      HEAD_SEEN = 3
      BODY_SEEN = 10

      private

      def html_tree_reset
        @h_names = []
        @h_level = 0
        @h_discard = 0
      end

      def html_tree_push(name)
        if name == "head"
          @h_level = HEAD_SEEN if @h_level < HEAD_SEEN
        elsif name == "body"
          @h_level = BODY_SEEN
        end
        @h_names << name
      end

      def html_tree_pop
        @h_names.pop
      end

      def html_tree_top
        @h_names.last
      end

      def html_tree_open?
        !@h_names.empty?
      end

      # Applies the rules for a start tag. Returns true if the parser
      # must drop the tag. offset is the end of the tag name.
      def html_tree_start(name, offset)
        html_auto_close(name)
        names = @h_names
        # After the body starts, only html, head, and body need more rules.
        if @h_level >= BODY_SEEN && !names.empty? && !TOP_NAMES[name]
          return false
        end

        html_check_implied(name)
        misplaced = if name == "html"
          !names.empty?
        elsif name == "head"
          names.length != 1
        else
          name == "body" && names.include?("body")
        end
        return false unless misplaced

        html_tree_error("htmlParseStartTag: misplaced <#{name}> tag", offset)
        @h_discard += 1
        true
      end

      # Applies the rules for an end tag. offset is the end of the tag.
      def html_tree_end(name, offset)
        # Most end tags close the current element.
        if @h_names.last == name && @h_discard == 0
          html_close_top
          return
        end

        if @h_discard > 0 && (name == "html" || name == "body" || name == "head")
          @h_discard -= 1
          return
        end

        names = @h_names
        unless names.include?(name)
          html_tree_error("Unexpected end tag : #{name}", offset)
          return
        end

        priority = END_PRIORITY.fetch(name, DEFAULT_PRIORITY)
        index = names.length - 1
        blocked = false
        while names[index] != name
          if END_PRIORITY.fetch(names[index], DEFAULT_PRIORITY) > priority
            blocked = true
            break
          end
          index -= 1
        end
        unless blocked
          while (top = names.last) != name
            html_tree_error("Opening and ending tag mismatch: #{name} and #{top}", offset) if END_TAG_EXPECTED[top]
            html_close_top
          end
        end
        top = names.last
        if top == name
          html_close_top
        else
          html_tree_error("Opening and ending tag mismatch: #{name} and #{top}", offset)
        end
      end

      # Text that is not blank goes into a paragraph if no element that
      # takes text is open.
      def html_tree_paragraph
        top = @h_names.last
        return unless top.nil? || top == "html" || top == "head"

        html_auto_close("p")
        html_check_implied("p")
        html_open_implied("p")
      end

      def html_auto_close(name)
        closes = START_CLOSE[name]
        return unless closes

        while (top = @h_names.last) && closes[top]
          html_close_top
        end
      end

      def html_check_implied(name)
        return if name == "html"

        names = @h_names
        html_open_implied("html") if names.empty?
        return if name == "body" || name == "head"

        if names.length <= 1 && HEAD_NAMES[name]
          html_open_implied("head") if @h_level < HEAD_SEEN
        elsif @h_level < BODY_SEEN && !FRAME_NAMES[name]
          return if names.include?("body") || names.include?("head")

          html_open_implied("body")
        end
      end
    end
  end
end
