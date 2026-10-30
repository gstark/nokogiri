# frozen_string_literal: true

require_relative "model"
require_relative "quirks"

module Nokogiri
  module Pure
    module Html5
      class Node
        attr_accessor :data
      end

      # HTML5 tree constructor. Behavior follows gumbo-parser parser.c.
      class TreeBuilder
        SCOPE = Object.new

        KNOWN = %w[
          html head title base link meta style script noscript template body
          article section nav aside h1 h2 h3 h4 h5 h6 hgroup header footer
          address p hr pre blockquote ol ul li dl dt dd figure figcaption main
          div a em strong small s cite q dfn abbr data time code var samp kbd
          sub sup i b u mark ruby rt rp bdi bdo span br wbr ins del image img
          iframe embed object param video audio source track canvas map area
          math mi mo mn ms mtext mglyph malignmark annotation-xml svg
          foreignobject desc table caption colgroup col tbody thead tfoot tr td
          th form fieldset legend label input button select datalist optgroup
          option textarea keygen output progress meter details summary menu
          menuitem applet acronym bgsound dir frame frameset noframes listing
          xmp nextid noembed plaintext rb strike basefont big blink center font
          marquee multicol nobr spacer tt rtc dialog search
        ].freeze
        KNOWN_SET = KNOWN.to_set.freeze

        SVG_TAGS = {
          "altglyph" => "altGlyph",
          "altglyphdef" => "altGlyphDef",
          "altglyphitem" => "altGlyphItem",
          "animatecolor" => "animateColor",
          "animatemotion" => "animateMotion",
          "animatetransform" => "animateTransform",
          "clippath" => "clipPath",
          "feblend" => "feBlend",
          "fecolormatrix" => "feColorMatrix",
          "fecomponenttransfer" => "feComponentTransfer",
          "fecomposite" => "feComposite",
          "feconvolvematrix" => "feConvolveMatrix",
          "fediffuselighting" => "feDiffuseLighting",
          "fedisplacementmap" => "feDisplacementMap",
          "fedistantlight" => "feDistantLight",
          "feflood" => "feFlood",
          "fefunca" => "feFuncA",
          "fefuncb" => "feFuncB",
          "fefuncg" => "feFuncG",
          "fefuncr" => "feFuncR",
          "fegaussianblur" => "feGaussianBlur",
          "feimage" => "feImage",
          "femerge" => "feMerge",
          "femergenode" => "feMergeNode",
          "femorphology" => "feMorphology",
          "feoffset" => "feOffset",
          "fepointlight" => "fePointLight",
          "fespecularlighting" => "feSpecularLighting",
          "fespotlight" => "feSpotLight",
          "fetile" => "feTile",
          "feturbulence" => "feTurbulence",
          "foreignobject" => "foreignObject",
          "glyphref" => "glyphRef",
          "lineargradient" => "linearGradient",
          "radialgradient" => "radialGradient",
          "textpath" => "textPath"
        }.freeze

        SVG_ATTRS = {
          "attributename" => "attributeName",
          "attributetype" => "attributeType",
          "basefrequency" => "baseFrequency",
          "baseprofile" => "baseProfile",
          "calcmode" => "calcMode",
          "clippathunits" => "clipPathUnits",
          "diffuseconstant" => "diffuseConstant",
          "edgemode" => "edgeMode",
          "filterunits" => "filterUnits",
          "glyphref" => "glyphRef",
          "gradienttransform" => "gradientTransform",
          "gradientunits" => "gradientUnits",
          "kernelmatrix" => "kernelMatrix",
          "kernelunitlength" => "kernelUnitLength",
          "keypoints" => "keyPoints",
          "keysplines" => "keySplines",
          "keytimes" => "keyTimes",
          "lengthadjust" => "lengthAdjust",
          "limitingconeangle" => "limitingConeAngle",
          "markerheight" => "markerHeight",
          "markerunits" => "markerUnits",
          "markerwidth" => "markerWidth",
          "maskcontentunits" => "maskContentUnits",
          "maskunits" => "maskUnits",
          "numoctaves" => "numOctaves",
          "pathlength" => "pathLength",
          "patterncontentunits" => "patternContentUnits",
          "patterntransform" => "patternTransform",
          "patternunits" => "patternUnits",
          "pointsatx" => "pointsAtX",
          "pointsaty" => "pointsAtY",
          "pointsatz" => "pointsAtZ",
          "preservealpha" => "preserveAlpha",
          "preserveaspectratio" => "preserveAspectRatio",
          "primitiveunits" => "primitiveUnits",
          "refx" => "refX",
          "refy" => "refY",
          "repeatcount" => "repeatCount",
          "repeatdur" => "repeatDur",
          "requiredextensions" => "requiredExtensions",
          "requiredfeatures" => "requiredFeatures",
          "specularconstant" => "specularConstant",
          "specularexponent" => "specularExponent",
          "spreadmethod" => "spreadMethod",
          "startoffset" => "startOffset",
          "stddeviation" => "stdDeviation",
          "stitchtiles" => "stitchTiles",
          "surfacescale" => "surfaceScale",
          "systemlanguage" => "systemLanguage",
          "tablevalues" => "tableValues",
          "targetx" => "targetX",
          "targety" => "targetY",
          "textlength" => "textLength",
          "viewbox" => "viewBox",
          "viewtarget" => "viewTarget",
          "xchannelselector" => "xChannelSelector",
          "ychannelselector" => "yChannelSelector",
          "zoomandpan" => "zoomAndPan"
        }.freeze

        FOREIGN_ATTRS = {
          "xlink:actuate" => ["actuate", :xlink],
          "xlink:arcrole" => ["arcrole", :xlink],
          "xlink:href" => ["href", :xlink],
          "xlink:role" => ["role", :xlink],
          "xlink:show" => ["show", :xlink],
          "xlink:title" => ["title", :xlink],
          "xlink:type" => ["type", :xlink],
          "xml:lang" => ["lang", :xml],
          "xml:space" => ["space", :xml],
          "xmlns" => ["xmlns", :xmlns],
          "xmlns:xlink" => ["xlink", :xmlns]
        }.freeze

        HEADING = %w[h1 h2 h3 h4 h5 h6].to_set.freeze
        DD_DT = %w[dd dt].to_set.freeze
        TD_TH = %w[td th].to_set.freeze
        IMPLIED = %w[dd dt li optgroup option p rb rp rt rtc].to_set.freeze
        IMPLIED_THOROUGH = %w[
          caption colgroup dd dt li optgroup option p rb rp rt rtc tbody td
          tfoot th thead tr
        ].to_set.freeze
        CLOSABLE = %w[
          dd dt li optgroup option p rb rp rt rtc tbody td tfoot th thead tr
          body html
        ].to_set.freeze
        BLOCK_START = %w[
          address article aside blockquote center details dialog dir div dl
          fieldset figcaption figure footer header hgroup main menu nav ol p
          section summary ul search
        ].to_set.freeze
        BLOCK_END = %w[
          address article aside blockquote button center details dialog dir div
          dl fieldset figcaption figure footer header hgroup listing main menu
          nav ol pre section summary ul search
        ].to_set.freeze
        FORMAT_START = %w[b big code em font i s small strike strong tt u].to_set.freeze
        FORMAT_END = %w[a b big code em font i nobr s small strike strong tt u].to_set.freeze
        HEAD_ELS = %w[
          base basefont bgsound link meta noframes script style template title
        ].to_set.freeze
        VOID_BODY = %w[area br embed img image keygen wbr].to_set.freeze
        TABLE_END_BANS = %w[
          body caption col colgroup html tbody td tfoot th thead tr
        ].to_set.freeze
        CELL_START_CLOSE = %w[
          caption col colgroup tbody td tfoot th thead tr
        ].to_set.freeze
        SELECT_TABLE = %w[
          caption table tbody tfoot thead tr td th
        ].to_set.freeze
        FOREIGN_BREAK_START = %w[
          b big blockquote body br center code dd div dl dt em embed h1 h2 h3
          h4 h5 h6 head hr i img li listing menu meta nobr ol p pre ruby s small
          span strong strike sub sup table tt u ul var
        ].to_set.freeze
        MATH_TEXT = %w[mi mo mn ms mtext].to_set.freeze

        def self.scope_set(pairs)
          pairs.map { |ns, name| [ns, name] }.to_set.freeze
        end

        DEFAULT_SCOPE = scope_set([
          [:html, "applet"], [:html, "caption"], [:html, "html"], [:html, "table"],
          [:html, "td"], [:html, "th"], [:html, "marquee"], [:html, "object"],
          [:html, "template"],
          [:mathml, "mi"], [:mathml, "mo"], [:mathml, "mn"], [:mathml, "ms"],
          [:mathml, "mtext"], [:mathml, "annotation-xml"],
          [:svg, "foreignobject"], [:svg, "desc"], [:svg, "title"]
        ]).freeze
        LIST_SCOPE = (DEFAULT_SCOPE | [[:html, "ol"], [:html, "ul"]]).freeze
        BUTTON_SCOPE = (DEFAULT_SCOPE | [[:html, "button"]]).freeze
        TABLE_SCOPE = scope_set([[:html, "html"], [:html, "table"], [:html, "template"]]).freeze
        SELECT_SCOPE = scope_set([[:html, "optgroup"], [:html, "option"]]).freeze
        OPEN_SCOPE = scope_set([[:html, "html"]]).freeze
        SPECIAL = scope_set([
          [:html, "address"], [:html, "applet"], [:html, "area"], [:html, "article"],
          [:html, "aside"], [:html, "base"], [:html, "basefont"], [:html, "bgsound"],
          [:html, "blockquote"], [:html, "body"], [:html, "br"], [:html, "button"],
          [:html, "caption"], [:html, "center"], [:html, "col"], [:html, "colgroup"],
          [:html, "dd"], [:html, "details"], [:html, "dir"], [:html, "div"],
          [:html, "dl"], [:html, "dt"], [:html, "embed"], [:html, "fieldset"],
          [:html, "figcaption"], [:html, "figure"], [:html, "footer"], [:html, "form"],
          [:html, "frame"], [:html, "frameset"],
          [:html, "h1"], [:html, "h2"], [:html, "h3"], [:html, "h4"], [:html, "h5"], [:html, "h6"],
          [:html, "head"], [:html, "header"], [:html, "hgroup"], [:html, "hr"],
          [:html, "html"], [:html, "iframe"], [:html, "img"], [:html, "input"],
          [:html, "li"], [:html, "link"], [:html, "listing"], [:html, "marquee"],
          [:html, "menu"], [:html, "meta"], [:html, "nav"], [:html, "noembed"],
          [:html, "noframes"], [:html, "noscript"], [:html, "object"], [:html, "ol"],
          [:html, "p"], [:html, "param"], [:html, "plaintext"], [:html, "pre"],
          [:html, "script"], [:html, "section"], [:html, "select"], [:html, "style"],
          [:html, "summary"], [:html, "table"], [:html, "tbody"], [:html, "td"],
          [:html, "template"], [:html, "textarea"], [:html, "tfoot"], [:html, "th"],
          [:html, "thead"], [:html, "tr"], [:html, "ul"], [:html, "wbr"], [:html, "xmp"],
          [:mathml, "mi"], [:mathml, "mo"], [:mathml, "mn"], [:mathml, "ms"],
          [:mathml, "mtext"], [:mathml, "annotation-xml"],
          [:svg, "foreignobject"], [:svg, "desc"], [:svg, "title"],
          [:html, "title"]
        ]).freeze
        TABLE_CONTEXT = scope_set([
          [:html, "html"], [:html, "table"], [:html, "template"]
        ]).freeze
        TABLE_BODY_CONTEXT = scope_set([
          [:html, "html"], [:html, "tbody"], [:html, "tfoot"], [:html, "thead"],
          [:html, "template"]
        ]).freeze
        TABLE_ROW_CONTEXT = scope_set([
          [:html, "html"], [:html, "tr"], [:html, "template"]
        ]).freeze
        TABLE_TEXT_NODES = scope_set([
          [:html, "table"], [:html, "tbody"], [:html, "template"], [:html, "tfoot"],
          [:html, "thead"], [:html, "tr"]
        ]).freeze
        FOSTER_TARGETS = scope_set([
          [:html, "table"], [:html, "tbody"], [:html, "tfoot"], [:html, "thead"],
          [:html, "tr"]
        ]).freeze
        HTML_END_OK = scope_set([[:html, "head"], [:html, "body"], [:html, "html"], [:html, "br"]]).freeze

        MODES = %i[
          initial before_html before_head in_head in_head_noscript after_head
          in_body text in_table in_table_text in_caption in_column_group
          in_table_body in_row in_cell in_select in_select_in_table in_template
          after_body in_frameset after_frameset after_after_body
          after_after_frameset
        ].freeze

        def self.parse(input, **options)
          new(input, options).parse
        end

        def initialize(input, options)
          @input = input
          @max_attributes = options.fetch(:max_attributes, 400)
          @max_errors = options.fetch(:max_errors, 0)
          @max_tree_depth = options.fetch(:max_tree_depth, 400)
          @noscript_as_text = options.fetch(:parse_noscript_content_as_text, false)
          @fragment_context = options[:fragment_context]
          @fragment_ns = normalize_ns(options.fetch(:fragment_namespace, :html))
          @fragment_encoding = options[:fragment_encoding]
          @fragment_quirks = options.fetch(:quirks_mode, 0)
          @form_ancestor = options.fetch(:fragment_context_has_form_ancestor, false)
          @errors = ErrorLog.new(@max_errors)
          @document = Node.new(:document)
          @document.doctype_name = ""
          @document.public_id = ""
          @document.system_id = ""
          @document.quirks_mode = 0
          @root = nil
          @open = []
          @formatting = []
          @template_modes = []
          @mode = :initial
          @original_mode = :initial
          @head = nil
          @form = nil
          @fragment_ctx = nil
          @reprocess = false
          @ack = false
          @frameset_ok = true
          @ignore_lf = false
          @foster = false
          @text = +""
          @text_kind = :whitespace
          @text_line = nil
          @table_tokens = []
          @current = nil
          @tree_too_deep = false
          @tokenizer = Tokenizer.new(@input, @errors, max_attributes: @max_attributes)
        end

        def parse
          init_fragment if @fragment_context
          token = nil
          loop do
            if @reprocess
              @reprocess = false
              token = @current
            else
              adjusted = adjusted_current
              @tokenizer.adjusted_current_node_foreign = !!(adjusted && adjusted.namespace != :html)
              if depth_exceeded?
                @tree_too_deep = true
                token = eof_token
              else
                token = @tokenizer.next_token
                token = eof_token if token.nil?
              end
            end
            @current = token
            @ack = false
            if @ignore_lf
              drop_lf = token.type == :whitespace && text_of(token) == "\n"
              @ignore_lf = false
              next if drop_lf
            end
            handle_token(token)
            unless @reprocess
              if token.type == :start_tag && token.self_closing && !@ack
                add_solidus_error(token)
              end
            end
            break if token.type == :eof && !@reprocess
          end
          finish_parsing
          raise ArgumentError, "Document tree depth limit exceeded" if @tree_too_deep
          if @tokenizer.too_many_attributes
            raise ArgumentError, "Attributes per element limit exceeded"
          end

          {
            document: @document,
            root: @root,
            errors: @errors.errors,
            quirks_mode: @document.quirks_mode
          }
        end

        private

        def normalize_ns(ns)
          case ns.to_s
          when "svg" then :svg
          when "mathml" then :mathml
          else :html
          end
        end

        def depth_exceeded?
          @max_tree_depth >= 0 && @open.length > @max_tree_depth
        end

        def eof_token
          token = Token.new
          token.type = :eof
          token.line = @current&.line
          token.column = @current&.column
          token.byte_offset = @current&.byte_offset
          token
        end

        def down(value)
          value.to_s.tr("A-Z", "a-z")
        end

        def known?(name)
          KNOWN_SET.include?(down(name))
        end

        def text_of(token)
          data = token.data
          return data.chr(Encoding::UTF_8) if data.is_a?(Integer)
          return data.to_s unless data.nil?
          return token.name.to_s if token.type == :comment || token.type == :cdata

          ""
        end

        def init_fragment
          raw = @fragment_context.to_s
          key = down(raw)
          name = known?(key) ? key : raw
          @fragment_ctx = make_element(name, @fragment_ns, [], nil)
          if @fragment_encoding
            @fragment_ctx.attrs << ["encoding", @fragment_encoding.to_s, nil]
          end
          @document.quirks_mode = @fragment_quirks
          if @fragment_ns == :html
            @tokenizer.state = fragment_state(key)
          end
          html = make_element("html", :html, [], nil)
          insert_element(html)
          @root = html
          @template_modes << :in_template if key == "template"
          reset_mode
          if @form_ancestor || (key == "form" && @fragment_ns == :html)
            @form = make_element("form", :html, [], nil)
          end
        end

        def fragment_state(name)
          case name
          when "title", "textarea" then :rcdata
          when "style", "xmp", "iframe", "noembed", "noframes" then :rawtext
          when "script" then :script_data
          when "noscript" then (@noscript_as_text ? :rawtext : :data)
          when "plaintext" then :plaintext
          else :data
          end
        end

        def current_node
          @open.last
        end

        def adjusted_current
          return @fragment_ctx if @open.length == 1 && @fragment_ctx

          current_node
        end

        def html?(node, name)
          node && node.type == :element && node.namespace == :html && down(node.name) == name
        end

        def html_in?(node, set)
          node && node.type == :element && node.namespace == :html && set.include?(down(node.name))
        end

        def ns_key(node)
          return nil unless node && node.type == :element

          [node.namespace, down(node.name)]
        end

        def ns_in?(node, set)
          key = ns_key(node)
          key && set.include?(key)
        end

        def tag?(token, kind, name)
          token.type == kind && down(token.name) == name
        end

        def tags?(token, kind, set)
          token.type == kind && set.include?(down(token.name))
        end

        def special?(node)
          ns_in?(node, SPECIAL)
        end

        def mathml_ip?(node)
          node && node.namespace == :mathml && MATH_TEXT.include?(down(node.name))
        end

        def html_ip?(node)
          return false unless node && node.type == :element
          return true if node.namespace == :svg && %w[foreignobject desc title].include?(down(node.name))
          return false unless node.namespace == :mathml && down(node.name) == "annotation-xml"

          attr_is?(node.attrs, "encoding", "text/html") ||
            attr_is?(node.attrs, "encoding", "application/xhtml+xml")
        end

        def attr_is?(attrs, name, value)
          found = attr_value(attrs, name)
          found && down(found) == down(value)
        end

        def attr_value(attrs, name)
          key = down(name)
          pair = attrs.find { |item| down(item[0]) == key }
          pair && pair[1].to_s
        end

        def has_attr?(token, name)
          key = down(name)
          (token.attrs || []).any? { |item| down(item[0]) == key }
        end

        def make_element(name, namespace, attrs, line)
          node = Node.new(:element)
          node.name = name
          node.namespace = namespace
          node.attrs = attrs
          node.line = line
          node
        end

        def html_attrs(token)
          (token.attrs || []).map { |item| [item[0].to_s, item[1].to_s, nil] }
        end

        def foreign_attrs(token, namespace)
          (token.attrs || []).map do |item|
            lname = item[0].to_s
            value = item[1].to_s
            if namespace == :mathml && down(lname) == "definitionurl"
              lname = "definitionURL"
            end
            if namespace == :svg
              repl = SVG_ATTRS[down(lname)]
              lname = repl if repl
            end
            ns = nil
            mapped = FOREIGN_ATTRS[lname]
            if mapped
              lname = mapped[0]
              ns = mapped[1]
            end
            [lname, value, ns]
          end
        end

        def foreign_tag_name(token, namespace, adjust_tag)
          raw = token.name.to_s
          key = down(raw)
          if namespace == :svg && adjust_tag
            return "foreignObject" if key == "foreignobject"
            if !KNOWN_SET.include?(key) && SVG_TAGS[key]
              return SVG_TAGS[key]
            end
          end
          KNOWN_SET.include?(key) ? key : raw
        end

        def append_node(parent, node)
          node.parent = parent
          parent.children << node
        end

        def insert_at(parent, node, index)
          node.parent = parent
          if index.nil?
            parent.children << node
          else
            parent.children.insert(index, node)
          end
        end

        def detach(node)
          return unless node.parent

          node.parent.children.delete(node)
          node.parent = nil
        end

        def insertion_location(override)
          target = override
          target = (@root ? current_node : @document) if target.nil?
          return [target, nil] unless @foster && ns_in?(target, FOSTER_TARGETS)

          last_template = nil
          last_table = nil
          template_at = -1
          table_at = -1
          @open.each_with_index do |node, index|
            if html?(node, "template")
              last_template = node
              template_at = index
            end
            if html?(node, "table")
              last_table = node
              table_at = index
            end
          end
          if last_template && (last_table.nil? || template_at > table_at)
            return [last_template, nil]
          end
          return [@open[0], nil] if last_table.nil?
          if last_table.parent
            return [last_table.parent, last_table.parent.children.index(last_table)]
          end

          [@open[table_at - 1], nil]
        end

        def flush_text
          return if @text.empty?

          kind = (@text_kind == :cdata) ? :cdata : :text
          node = Node.new(kind)
          node.data = @text.dup
          node.content = node.data
          node.name = node.data
          node.line = @text_line
          target, index = insertion_location(nil)
          insert_at(target, node, index) unless target.type == :document
          @text = +""
          @text_kind = :whitespace
          @text_line = nil
        end

        def insert_text(token, replacement: false)
          if @text.empty?
            @text_line = token.line
          end
          @text << (replacement ? "\uFFFD" : text_of(token))
          if token.type == :character
            @text_kind = :text
          elsif token.type == :cdata
            @text_kind = :cdata
          end
        end

        def insert_element(node, flush: true)
          flush_text if flush
          target, index = insertion_location(nil)
          insert_at(target, node, index)
          @open << node
          node
        end

        def insert_html(token, name = nil)
          tag = name || token.name
          key = down(tag)
          tag = key if KNOWN_SET.include?(key)
          node = make_element(tag, :html, html_attrs(token), token.line)
          insert_element(node)
        end

        def insert_implied(name)
          node = make_element(name, :html, [], @current&.line)
          insert_element(node)
        end

        def insert_foreign(token, namespace, adjust_tag: false)
          name = foreign_tag_name(token, namespace, adjust_tag)
          node = make_element(name, namespace, foreign_attrs(token, namespace), token.line)
          insert_element(node)
          if token.self_closing
            pop_current_node
            @ack = true
          end
          node
        end

        def pop_current_node
          flush_text
          @open.pop
        end

        # The condition must pop. A modifier until would pop a second node.
        def pop_through_html(name)
          loop do
            node = pop_current_node
            break if node.nil? || html?(node, name)
          end
        end

        def append_comment(parent, token)
          flush_text
          node = Node.new(:comment)
          node.data = text_of(token)
          node.content = node.data
          node.name = node.data
          node.line = token.line
          append_node(parent, node)
        end

        def acknowledge
          @ack = true
        end

        def frameset_not_ok
          @frameset_ok = false
        end

        def reprocess!
          @reprocess = true
        end

        def add_error(token)
          @errors.add(
            code: "generic-parser",
            message: error_message(token),
            line: token.line,
            column: token.column,
            byte_offset: token.byte_offset
          )
        end

        def add_solidus_error(token)
          @errors.add(
            code: "non-void-html-element-start-tag-with-trailing-solidus",
            message: "Start tag of nonvoid HTML element ends with '/>', use '>'.",
            line: token.line,
            column: token.column,
            byte_offset: token.byte_offset
          )
        end

        def token_error_name(token)
          raw = token.name.to_s
          key = down(raw)
          KNOWN_SET.include?(key) ? key : raw
        end

        def node_error_name(node)
          raw = node.name.to_s
          key = down(raw)
          KNOWN_SET.include?(key) ? key : raw
        end

        def tag_stack_message
          names = @open.map { |node| node_error_name(node) }
          " Currently open tags: #{names.join(", ")}."
        end

        def error_message(token)
          if @mode == :initial && token.type != :doctype
            return "Expected a doctype token"
          end

          case token.type
          when :doctype
            "This is not a legal doctype"
          when :comment
            "Comments aren't legal here"
          when :cdata, :whitespace, :character
            "Character tokens aren't legal here"
          when :null
            "Null bytes are not allowed in HTML5"
          when :eof
            if @mode == :initial
              "You must provide a doctype"
            else
              "Premature end of file.#{tag_stack_message}"
            end
          when :start_tag
            "Start tag '#{token_error_name(token)}' isn't allowed here.#{tag_stack_message}"
          when :end_tag
            "End tag '#{token_error_name(token)}' isn't allowed here.#{tag_stack_message}"
          else
            "Character tokens aren't legal here"
          end
        end

        def has_in_scope?(names, scope, negate: false)
          expected = Array(names)
          index = @open.length - 1
          while index >= 0
            node = @open[index]
            index -= 1
            next unless node.type == :element
            if node.namespace == :html && expected.include?(down(node.name))
              return true
            end

            found = ns_in?(node, scope)
            return false if negate != found
          end
          false
        end

        def has_scope?(name)
          has_in_scope?(name, DEFAULT_SCOPE)
        end

        def has_list_scope?(name)
          has_in_scope?(name, LIST_SCOPE)
        end

        def has_button_scope?(name)
          has_in_scope?(name, BUTTON_SCOPE)
        end

        def has_table_scope?(name)
          has_in_scope?(name, TABLE_SCOPE)
        end

        def has_select_scope?(name)
          has_in_scope?(name, SELECT_SCOPE, negate: true)
        end

        def has_open?(name)
          has_in_scope?(name, OPEN_SCOPE)
        end

        def has_node_in_scope?(node)
          index = @open.length - 1
          while index >= 0
            current = @open[index]
            index -= 1
            return true if current.equal?(node)
            next unless current.type == :element
            return false if ns_in?(current, DEFAULT_SCOPE)
          end
          false
        end

        def has_heading_in_scope?
          has_in_scope?(HEADING.to_a, DEFAULT_SCOPE)
        end

        def on_open_stack?(node)
          @open.any? { |item| item.equal?(node) }
        end

        def generate_implied(exception = nil)
          while (node = current_node) && html_in?(node, IMPLIED) && !(exception && html?(node, exception))
            pop_current_node
          end
        end

        def generate_implied_thoroughly
          pop_current_node while html_in?(current_node, IMPLIED_THOROUGH)
        end

        def nonclosable_on_stack?
          @open.any? { |node| !html_in?(node, CLOSABLE) }
        end

        def implicitly_close(token, namespace, name)
          key = down(name)
          generate_implied((namespace == :html) ? key : nil)
          unless current_node && current_node.namespace == namespace && down(current_node.name) == key
            add_error(token)
            until current_node && current_node.namespace == namespace && down(current_node.name) == key
              pop_current_node
            end
          end
          pop_current_node
        end

        def close_p(token)
          return unless has_button_scope?("p")

          implicitly_close(token, :html, "p")
        end

        def close_list(token, is_li)
          frameset_not_ok
          index = @open.length - 1
          while index >= 0
            node = @open[index]
            index -= 1
            match = is_li ? html?(node, "li") : html_in?(node, DD_DT)
            if match
              implicitly_close(token, node.namespace, node.name)
              return
            end
            if special?(node) && !html_in?(node, %w[address div p].to_set)
              return
            end
          end
        end

        def close_table
          return false unless has_table_scope?("table")

          node = pop_current_node
          node = pop_current_node until html?(node, "table")
          reset_mode
          true
        end

        def close_cell(token, name)
          generate_implied
          add_error(token) unless html?(current_node, name)
          node = nil
          node = pop_current_node until html?(node, name)
          clear_formatting
          @mode = :in_row
        end

        def close_current_cell(token)
          name = has_table_scope?("td") ? "td" : "th"
          close_cell(token, name)
        end

        def close_select
          node = pop_current_node
          node = pop_current_node until html?(node, "select")
          reset_mode
        end

        def clear_stack_to(set)
          pop_current_node until ns_in?(current_node, set)
        end

        def clear_formatting
          loop do
            node = @formatting.pop
            break if node.nil? || node.equal?(SCOPE)
          end
        end

        def attrs_match?(left, right)
          unmatched = right.length
          left.each do |name, value, _ns|
            if right.any? { |other_name, other_value, _| other_name == name && other_value == value }
              unmatched -= 1
            else
              return false
            end
          end
          unmatched == 0
        end

        def same_formatting?(left, right)
          left.namespace == right.namespace && down(left.name) == down(right.name) &&
            attrs_match?(left.attrs, right.attrs)
        end

        def add_formatting(node)
          unless node.equal?(SCOPE)
            earliest = nil
            count = 0
            (@formatting.length - 1).downto(0) do |index|
              other = @formatting[index]
              break if other.equal?(SCOPE)
              next unless same_formatting?(other, node)

              count += 1
              earliest = index
            end
            @formatting.delete_at(earliest) if count >= 3 && earliest
          end
          @formatting << node
        end

        def clone_node(node)
          copy = Node.new(:element)
          copy.name = node.name
          copy.namespace = node.namespace
          copy.line = node.line
          copy.attrs = node.attrs.map(&:dup)
          copy
        end

        def reconstruct
          return if @formatting.empty?

          index = @formatting.length - 1
          element = @formatting[index]
          return if element.equal?(SCOPE) || on_open_stack?(element)

          loop do
            if index == 0
              index = -1
              break
            end
            index -= 1
            element = @formatting[index]
            break if element.equal?(SCOPE) || on_open_stack?(element)
          end
          index += 1
          while index < @formatting.length
            element = @formatting[index]
            copy = clone_node(element)
            target, at = insertion_location(nil)
            insert_at(target, copy, at)
            @open << copy
            @formatting[index] = copy
            index += 1
          end
        end

        def merge_attrs(token, node)
          (token.attrs || []).each do |item|
            name = item[0].to_s
            value = item[1].to_s
            next if node.attrs.any? { |existing, _, _| down(existing) == down(name) }

            node.attrs << [name, value, nil]
          end
        end

        def run_generic(token, state)
          insert_html(token)
          @tokenizer.state = state
          @original_mode = @mode
          @mode = :text
        end

        def any_other_end_tag(token)
          name = down(token.name)
          index = @open.length - 1
          while index >= 0
            node = @open[index]
            index -= 1
            if node.namespace == :html && down(node.name) == name
              generate_implied(name)
              add_error(token) unless current_node.equal?(node)
              loop do
                popped = pop_current_node
                break if popped.equal?(node)
              end
              return
            elsif special?(node)
              add_error(token)
              return
            end
          end
        end

        def adoption_agency(token)
          subject = down(token.name)
          if html?(current_node, subject) && @formatting.none? { |node| node.equal?(current_node) }
            pop_current_node
            return
          end

          8.times do
            formatting = nil
            open_index = nil
            (@formatting.length - 1).downto(0) do |index|
              node = @formatting[index]
              break if node.equal?(SCOPE)
              next unless html?(node, subject)

              formatting = node
              open_index = @open.index { |item| item.equal?(formatting) }
              break
            end
            unless formatting
              any_other_end_tag(token)
              return
            end
            if open_index.nil?
              add_error(token)
              @formatting.delete_if { |node| node.equal?(formatting) }
              return
            end
            unless has_scope?(subject)
              add_error(token)
              return
            end
            add_error(token) unless formatting.equal?(current_node)

            furthest = nil
            open_index.upto(@open.length - 1) do |index|
              node = @open[index]
              if special?(node)
                furthest = node
                break
              end
            end
            unless furthest
              loop do
                popped = pop_current_node
                break if popped.nil? || popped.equal?(formatting)
              end
              remove_formatting(formatting)
              return
            end

            common = @open[open_index - 1]
            bookmark = formatting_index(formatting) + 1
            node = furthest
            last = furthest
            saved = @open.index { |item| item.equal?(node) }
            inner = 0
            loop do
              inner += 1
              node_index = @open.index { |item| item.equal?(node) }
              node_index = saved if node_index.nil?
              saved = node_index - 1
              node_index = saved
              node = @open[node_index]
              break if node.equal?(formatting)

              fmt_index = formatting_index(node)
              if inner > 3 && fmt_index
                @formatting.delete_at(fmt_index)
                bookmark -= 1 if fmt_index < bookmark
                next
              end
              if fmt_index.nil?
                @open.delete_at(node_index)
                next
              end
              clone = clone_node(node)
              @formatting[fmt_index] = clone
              @open[node_index] = clone
              node = clone
              if last.equal?(furthest)
                bookmark = fmt_index + 1
              end
              detach(last)
              append_node(node, last)
              last = node
            end

            detach(last)
            target, at = insertion_location(common)
            insert_at(target, last, at)
            created = clone_node(formatting)
            created.children, furthest.children = furthest.children, created.children
            created.children.each { |child| child.parent = created }
            append_node(furthest, created)

            fmt_index = formatting_index(formatting)
            bookmark -= 1 if fmt_index && fmt_index < bookmark
            @formatting.delete_at(fmt_index) if fmt_index
            @formatting.insert(bookmark, created)
            @open.delete_if { |item| item.equal?(formatting) }
            at = @open.index { |item| item.equal?(furthest) }
            @open.insert(at + 1, created)
          end
        end

        def formatting_index(node)
          @formatting.index { |item| item.equal?(node) }
        end

        def remove_formatting(node)
          @formatting.delete_if { |item| item.equal?(node) }
        end

        def find_anchor
          index = @formatting.length - 1
          while index >= 0
            node = @formatting[index]
            index -= 1
            return nil if node.equal?(SCOPE)
            return index if html?(node, "a")
          end
          nil
        end

        def appropriate_mode(index)
          node = @open[index]
          last = index == 0
          node = @fragment_ctx if last && @fragment_ctx
          return (last ? :in_body : :initial) if node.namespace != :html

          case down(node.name)
          when "select"
            return :in_select if last

            ancestor_index = index
            while ancestor_index > 0
              ancestor = @open[ancestor_index]
              return :in_select if html?(ancestor, "template")
              return :in_select_in_table if html?(ancestor, "table")

              ancestor_index -= 1
            end
            :in_select
          when "td", "th"
            last ? :in_body : :in_cell
          when "tr"
            :in_row
          when "tbody", "thead", "tfoot"
            :in_table_body
          when "caption"
            :in_caption
          when "colgroup"
            :in_column_group
          when "table"
            :in_table
          when "template"
            @template_modes.last || :initial
          when "head"
            last ? :in_body : :in_head
          when "body"
            :in_body
          when "frameset"
            :in_frameset
          when "html"
            @head ? :after_head : :before_head
          else
            last ? :in_body : :initial
          end
        end

        def reset_mode
          index = @open.length - 1
          while index >= 0
            mode = appropriate_mode(index)
            unless mode == :initial
              @mode = mode
              return
            end
            index -= 1
          end
          @mode = :in_body
        end

        def finish_parsing
          flush_text
          pop_current_node while @open.any?
          @document.doctype_name = @document.doctype_name.to_s
          @document.public_id = @document.public_id.to_s
          @document.system_id = @document.system_id.to_s
        end

        def doctype_quirks(token)
          return Quirks::QUIRKS if token.force_quirks

          public_id = token.has_public_id ? token.public_id.to_s : nil
          system_id = token.has_system_id ? token.system_id.to_s : nil
          Quirks.compute(token.name, public_id, system_id, !!token.has_system_id)
        end

        def illegal_doctype?(token)
          return true if token.name != "html"
          return true if token.has_public_id
          return true if token.has_system_id && token.system_id.to_s != "about:legacy-compat"

          false
        end

        def handle_token(token)
          node = adjusted_current
          html_content = node.nil? ||
            node.namespace == :html ||
            (mathml_ip?(node) && (
              token.type == :character || token.type == :whitespace || token.type == :null ||
              (token.type == :start_tag && !tags?(token, :start_tag, %w[mglyph malignmark].to_set))
            )) ||
            (node.namespace == :mathml && down(node.name) == "annotation-xml" && tag?(token, :start_tag, "svg")) ||
            (html_ip?(node) && (
              token.type == :start_tag || token.type == :character || token.type == :null || token.type == :whitespace
            )) ||
            token.type == :eof
          if html_content
            handle_html(token)
          else
            handle_foreign(token)
          end
        end

        def handle_html(token)
          case @mode
          when :initial then handle_initial(token)
          when :before_html then handle_before_html(token)
          when :before_head then handle_before_head(token)
          when :in_head then handle_in_head(token)
          when :in_head_noscript then handle_in_head_noscript(token)
          when :after_head then handle_after_head(token)
          when :in_body then handle_in_body(token)
          when :text then handle_text(token)
          when :in_table then handle_in_table(token)
          when :in_table_text then handle_in_table_text(token)
          when :in_caption then handle_in_caption(token)
          when :in_column_group then handle_in_column_group(token)
          when :in_table_body then handle_in_table_body(token)
          when :in_row then handle_in_row(token)
          when :in_cell then handle_in_cell(token)
          when :in_select then handle_in_select(token)
          when :in_select_in_table then handle_in_select_in_table(token)
          when :in_template then handle_in_template(token)
          when :after_body then handle_after_body(token)
          when :in_frameset then handle_in_frameset(token)
          when :after_frameset then handle_after_frameset(token)
          when :after_after_body then handle_after_after_body(token)
          when :after_after_frameset then handle_after_after_frameset(token)
          end
        end

        def handle_initial(token)
          if token.type == :whitespace
            return
          end
          if token.type == :comment
            append_comment(@document, token)
            return
          end
          if token.type == :doctype
            @document.has_doctype = true
            @document.doctype_name = token.name.to_s
            @document.public_id = token.public_id.to_s
            @document.system_id = token.system_id.to_s
            @document.quirks_mode = doctype_quirks(token)
            @mode = :before_html
            add_error(token) if illegal_doctype?(token)
            return
          end
          add_error(token)
          @document.quirks_mode = Quirks::QUIRKS
          @mode = :before_html
          reprocess!
        end

        def handle_before_html(token)
          if token.type == :doctype
            add_error(token)
            return
          end
          if token.type == :comment
            append_comment(@document, token)
            return
          end
          if token.type == :whitespace
            return
          end
          if tag?(token, :start_tag, "html")
            node = insert_html(token)
            @root = node
            @mode = :before_head
            return
          end
          if token.type == :end_tag && !tags?(token, :end_tag, %w[head body html br].to_set)
            add_error(token)
            return
          end
          node = insert_implied("html")
          @root = node
          @mode = :before_head
          reprocess!
        end

        def handle_before_head(token)
          if token.type == :whitespace
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tag?(token, :start_tag, "head")
            @head = insert_html(token)
            @mode = :in_head
            return
          end
          if token.type == :end_tag && !tags?(token, :end_tag, %w[head body html br].to_set)
            add_error(token)
            return
          end
          @head = insert_implied("head")
          @mode = :in_head
          reprocess!
        end

        def handle_in_head(token)
          if token.type == :whitespace
            insert_text(token)
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tags?(token, :start_tag, %w[base basefont bgsound link].to_set)
            insert_html(token)
            pop_current_node
            acknowledge
            return
          end
          if tag?(token, :start_tag, "meta")
            insert_html(token)
            pop_current_node
            acknowledge
            return
          end
          if tag?(token, :start_tag, "title")
            run_generic(token, :rcdata)
            return
          end
          if tags?(token, :start_tag, %w[noframes style].to_set) ||
              (tag?(token, :start_tag, "noscript") && @noscript_as_text)
            run_generic(token, :rawtext)
            return
          end
          if tag?(token, :start_tag, "noscript")
            insert_html(token)
            @mode = :in_head_noscript
            return
          end
          if tag?(token, :start_tag, "script")
            run_generic(token, :script_data)
            return
          end
          if tag?(token, :end_tag, "head")
            pop_current_node
            @mode = :after_head
            return
          end
          if tags?(token, :end_tag, %w[body html br].to_set)
            pop_current_node
            @mode = :after_head
            reprocess!
            return
          end
          if tag?(token, :start_tag, "template")
            insert_html(token)
            add_formatting(SCOPE)
            frameset_not_ok
            @mode = :in_template
            @template_modes << :in_template
            return
          end
          if tag?(token, :end_tag, "template")
            unless has_open?("template")
              add_error(token)
              return
            end
            generate_implied_thoroughly
            add_error(token) unless html?(current_node, "template")
            pop_through_html("template")
            clear_formatting
            @template_modes.pop
            reset_mode
            return
          end
          if tag?(token, :start_tag, "head") || token.type == :end_tag
            add_error(token)
            return
          end
          pop_current_node
          @mode = :after_head
          reprocess!
        end

        def handle_in_head_noscript(token)
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tag?(token, :end_tag, "noscript")
            pop_current_node
            @mode = :in_head
            return
          end
          if token.type == :whitespace || token.type == :comment ||
              tags?(token, :start_tag, %w[basefont bgsound link meta noframes style].to_set)
            handle_in_head(token)
            return
          end
          if tags?(token, :start_tag, %w[head noscript].to_set) ||
              (token.type == :end_tag && !tag?(token, :end_tag, "br"))
            add_error(token)
            return
          end
          add_error(token)
          pop_current_node
          @mode = :in_head
          reprocess!
        end

        def handle_after_head(token)
          if token.type == :whitespace
            insert_text(token)
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tag?(token, :start_tag, "body")
            insert_html(token)
            frameset_not_ok
            @mode = :in_body
            return
          end
          if tag?(token, :start_tag, "frameset")
            insert_html(token)
            @mode = :in_frameset
            return
          end
          if tags?(token, :start_tag, HEAD_ELS)
            add_error(token)
            flush_text
            @open << @head
            handle_in_head(token)
            @open.delete_if { |node| node.equal?(@head) }
            return
          end
          if tag?(token, :end_tag, "template")
            handle_in_head(token)
            return
          end
          if tag?(token, :start_tag, "head") ||
              (token.type == :end_tag && !tags?(token, :end_tag, %w[body html br].to_set))
            add_error(token)
            return
          end
          insert_implied("body")
          @mode = :in_body
          reprocess!
        end

        def handle_in_body(token)
          if token.type == :null
            add_error(token)
            return
          end
          if token.type == :whitespace
            reconstruct
            insert_text(token)
            return
          end
          if token.type == :character || token.type == :cdata
            reconstruct
            insert_text(token)
            frameset_not_ok
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            add_error(token)
            if has_open?("template")
              return
            end
            merge_attrs(token, @root)
            return
          end
          if tags?(token, :start_tag, HEAD_ELS) || tag?(token, :end_tag, "template")
            handle_in_head(token)
            return
          end
          if tag?(token, :start_tag, "body")
            add_error(token)
            if @open.length < 2 || !html?(@open[1], "body") || has_open?("template")
              return
            end
            frameset_not_ok
            merge_attrs(token, @open[1])
            return
          end
          if tag?(token, :start_tag, "frameset")
            add_error(token)
            if @open.length < 2 || !html?(@open[1], "body") || !@frameset_ok
              return
            end
            body = @open[1]
            popped = nil
            popped = pop_current_node until popped.equal?(body)
            clear_formatting
            detach(body)
            insert_html(token)
            @mode = :in_frameset
            return
          end
          if token.type == :eof
            if @template_modes.any?
              handle_in_template(token)
              return
            end
            add_error(token) if nonclosable_on_stack?
            return
          end
          if tag?(token, :end_tag, "body")
            unless has_scope?("body")
              add_error(token)
              return
            end
            add_error(token) if nonclosable_on_stack?
            @mode = :after_body
            return
          end
          if tag?(token, :end_tag, "html")
            unless has_scope?("body")
              add_error(token)
              return
            end
            add_error(token) if nonclosable_on_stack?
            @mode = :after_body
            reprocess!
            return
          end
          if tags?(token, :start_tag, BLOCK_START)
            close_p(token)
            insert_html(token)
            return
          end
          if tags?(token, :start_tag, HEADING)
            close_p(token)
            if html_in?(current_node, HEADING)
              add_error(token)
              pop_current_node
            end
            insert_html(token)
            return
          end
          if tags?(token, :start_tag, %w[pre listing].to_set)
            close_p(token)
            insert_html(token)
            @ignore_lf = true
            frameset_not_ok
            return
          end
          if tag?(token, :start_tag, "form")
            if @form && !has_open?("template")
              add_error(token)
              return
            end
            close_p(token)
            form = insert_html(token)
            @form = form unless has_open?("template")
            return
          end
          if tag?(token, :start_tag, "li")
            close_list(token, true)
            close_p(token)
            insert_html(token)
            return
          end
          if tags?(token, :start_tag, DD_DT)
            close_list(token, false)
            close_p(token)
            insert_html(token)
            return
          end
          if tag?(token, :start_tag, "plaintext")
            close_p(token)
            insert_html(token)
            @tokenizer.state = :plaintext
            return
          end
          if tag?(token, :start_tag, "button")
            if has_scope?("button")
              add_error(token)
              generate_implied
              pop_through_html("button")
            end
            reconstruct
            insert_html(token)
            frameset_not_ok
            return
          end
          if tags?(token, :end_tag, BLOCK_END)
            name = down(token.name)
            unless has_scope?(name)
              add_error(token)
              return
            end
            implicitly_close(token, :html, name)
            return
          end
          if tag?(token, :end_tag, "form")
            if has_open?("template")
              unless has_scope?("form")
                add_error(token)
                return
              end
              generate_implied
              add_error(token) unless html?(current_node, "form")
              pop_through_html("form")
              return
            end
            node = @form
            @form = nil
            if node.nil? || !has_node_in_scope?(node)
              add_error(token)
              return
            end
            flush_text
            generate_implied
            add_error(token) unless current_node.equal?(node)
            @open.delete_if { |item| item.equal?(node) }
            return
          end
          if tag?(token, :end_tag, "p")
            unless has_button_scope?("p")
              add_error(token)
              insert_implied("p")
            end
            implicitly_close(token, :html, "p")
            return
          end
          if tag?(token, :end_tag, "li")
            unless has_list_scope?("li")
              add_error(token)
              return
            end
            implicitly_close(token, :html, "li")
            return
          end
          if tags?(token, :end_tag, DD_DT)
            name = down(token.name)
            unless has_scope?(name)
              add_error(token)
              return
            end
            implicitly_close(token, :html, name)
            return
          end
          if tags?(token, :end_tag, HEADING)
            unless has_heading_in_scope?
              add_error(token)
              return
            end
            generate_implied
            add_error(token) unless html?(current_node, down(token.name))
            node = nil
            node = pop_current_node until html_in?(node, HEADING)
            return
          end
          if tag?(token, :start_tag, "a")
            anchor = find_anchor
            if anchor
              add_error(token)
              adoption_agency(token)
              if (again = find_anchor)
                removed = @formatting.delete_at(again)
                @open.delete_if { |item| item.equal?(removed) }
              end
            end
            reconstruct
            add_formatting(insert_html(token))
            return
          end
          if tags?(token, :start_tag, FORMAT_START)
            reconstruct
            add_formatting(insert_html(token))
            return
          end
          if tag?(token, :start_tag, "nobr")
            reconstruct
            if has_scope?("nobr")
              add_error(token)
              adoption_agency(token)
              reconstruct
            end
            insert_html(token)
            add_formatting(current_node)
            return
          end
          if tags?(token, :end_tag, FORMAT_END)
            adoption_agency(token)
            return
          end
          if tags?(token, :start_tag, %w[applet marquee object].to_set)
            reconstruct
            insert_html(token)
            add_formatting(SCOPE)
            frameset_not_ok
            return
          end
          if tags?(token, :end_tag, %w[applet marquee object].to_set)
            name = down(token.name)
            unless has_scope?(name)
              add_error(token)
              return
            end
            implicitly_close(token, :html, name)
            clear_formatting
            return
          end
          if tag?(token, :start_tag, "table")
            close_p(token) unless @document.quirks_mode == Quirks::QUIRKS
            insert_html(token)
            frameset_not_ok
            @mode = :in_table
            return
          end
          if tag?(token, :end_tag, "br")
            add_error(token)
            reconstruct
            insert_implied("br")
            pop_current_node
            acknowledge
            frameset_not_ok
            return
          end
          if tags?(token, :start_tag, VOID_BODY)
            image = tag?(token, :start_tag, "image")
            add_error(token) if image
            reconstruct
            node = image ? insert_html(token, "img") : insert_html(token)
            pop_current_node
            acknowledge
            frameset_not_ok
            return
          end
          if tag?(token, :start_tag, "input")
            reconstruct
            node = insert_html(token)
            pop_current_node
            acknowledge
            frameset_not_ok unless attr_is?(node.attrs, "type", "hidden")
            return
          end
          if tags?(token, :start_tag, %w[param source track].to_set)
            insert_html(token)
            pop_current_node
            acknowledge
            return
          end
          if tag?(token, :start_tag, "hr")
            close_p(token)
            insert_html(token)
            pop_current_node
            acknowledge
            frameset_not_ok
            return
          end
          if tag?(token, :start_tag, "textarea")
            run_generic(token, :rcdata)
            @ignore_lf = true
            frameset_not_ok
            return
          end
          if tag?(token, :start_tag, "xmp")
            close_p(token)
            reconstruct
            frameset_not_ok
            run_generic(token, :rawtext)
            return
          end
          if tag?(token, :start_tag, "iframe")
            frameset_not_ok
            run_generic(token, :rawtext)
            return
          end
          if tag?(token, :start_tag, "noembed") ||
              (tag?(token, :start_tag, "noscript") && @noscript_as_text)
            run_generic(token, :rawtext)
            return
          end
          if tag?(token, :start_tag, "select")
            reconstruct
            insert_html(token)
            frameset_not_ok
            @mode = if %i[in_table in_caption in_table_body in_row in_cell].include?(@mode)
              :in_select_in_table
            else
              :in_select
            end
            return
          end
          if tags?(token, :start_tag, %w[optgroup option].to_set)
            pop_current_node if html?(current_node, "option")
            reconstruct
            insert_html(token)
            return
          end
          if tags?(token, :start_tag, %w[rb rtc].to_set)
            if has_scope?("ruby")
              generate_implied
              add_error(token) unless html?(current_node, "ruby")
            end
            insert_html(token)
            return
          end
          if tags?(token, :start_tag, %w[rp rt].to_set)
            if has_scope?("ruby")
              generate_implied("rtc")
              current = current_node
              unless html?(current, "ruby") || html?(current, "rtc")
                add_error(token)
              end
            end
            insert_html(token)
            return
          end
          if tag?(token, :start_tag, "math")
            reconstruct
            insert_foreign(token, :mathml)
            return
          end
          if tag?(token, :start_tag, "svg")
            reconstruct
            insert_foreign(token, :svg)
            return
          end
          if tags?(token, :start_tag, %w[
            caption col colgroup frame head tbody td tfoot th thead tr
          ].to_set)
            add_error(token)
            return
          end
          if token.type == :start_tag
            reconstruct
            insert_html(token)
            return
          end
          any_other_end_tag(token)
        end

        def handle_text(token)
          if token.type == :character || token.type == :whitespace
            insert_text(token)
            return
          end
          if token.type == :eof
            add_error(token)
            reprocess!
          end
          pop_current_node
          @mode = @original_mode
        end

        def handle_in_table(token)
          if (token.type == :character || token.type == :whitespace || token.type == :null) &&
              ns_in?(current_node, TABLE_TEXT_NODES)
            @original_mode = @mode
            reprocess!
            @mode = :in_table_text
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "caption")
            clear_stack_to(TABLE_CONTEXT)
            add_formatting(SCOPE)
            insert_html(token)
            @mode = :in_caption
            return
          end
          if tag?(token, :start_tag, "colgroup")
            clear_stack_to(TABLE_CONTEXT)
            insert_html(token)
            @mode = :in_column_group
            return
          end
          if tag?(token, :start_tag, "col")
            clear_stack_to(TABLE_CONTEXT)
            insert_implied("colgroup")
            reprocess!
            @mode = :in_column_group
            return
          end
          if tags?(token, :start_tag, %w[tbody tfoot thead].to_set)
            clear_stack_to(TABLE_CONTEXT)
            insert_html(token)
            @mode = :in_table_body
            return
          end
          if tags?(token, :start_tag, %w[td th tr].to_set)
            clear_stack_to(TABLE_CONTEXT)
            insert_implied("tbody")
            @mode = :in_table_body
            reprocess!
            return
          end
          if tag?(token, :start_tag, "table")
            add_error(token)
            reprocess! if close_table
            return
          end
          if tag?(token, :end_tag, "table")
            add_error(token) unless close_table
            return
          end
          if tags?(token, :end_tag, TABLE_END_BANS)
            add_error(token)
            return
          end
          if tags?(token, :start_tag, %w[style script template].to_set) || tag?(token, :end_tag, "template")
            handle_in_head(token)
            return
          end
          if tag?(token, :start_tag, "input") && attr_is?(token.attrs || [], "type", "hidden")
            add_error(token)
            insert_html(token)
            pop_current_node
            acknowledge
            return
          end
          if tag?(token, :start_tag, "form")
            add_error(token)
            if @form || has_open?("template")
              return
            end
            @form = insert_html(token)
            pop_current_node
            return
          end
          if token.type == :eof
            handle_in_body(token)
            return
          end
          add_error(token)
          @foster = true
          handle_in_body(token)
          @foster = false
        end

        def handle_in_table_text(token)
          if token.type == :null
            add_error(token)
            return
          end
          if token.type == :whitespace || token.type == :character
            insert_text(token)
            @table_tokens << snapshot(token)
            return
          end
          unless @text_kind == :whitespace
            @table_tokens.each { |item| add_error(item) }
            @foster = true
            frameset_not_ok
            reconstruct
          end
          flush_text
          @table_tokens.clear
          @foster = false
          reprocess!
          @mode = @original_mode
        end

        def snapshot(token)
          copy = Token.new
          copy.type = token.type
          copy.line = token.line
          copy.column = token.column
          copy.byte_offset = token.byte_offset
          copy.name = token.name
          copy.data = token.data
          copy
        end

        def handle_in_caption(token)
          if tag?(token, :end_tag, "caption") ||
              tags?(token, :start_tag, CELL_START_CLOSE) ||
              tag?(token, :end_tag, "table")
            if tag?(token, :end_tag, "caption") || tags?(token, :start_tag, CELL_START_CLOSE) || tag?(token, :end_tag, "table")
              unless has_table_scope?("caption")
                add_error(token)
                return
              end
              generate_implied
              add_error(token) unless html?(current_node, "caption")
              pop_through_html("caption")
              clear_formatting
              @mode = :in_table
              reprocess! unless tag?(token, :end_tag, "caption")
              return
            end
          end
          if tags?(token, :end_tag, %w[body col colgroup html tbody td tfoot th thead tr].to_set)
            add_error(token)
            return
          end
          handle_in_body(token)
        end

        def handle_in_column_group(token)
          if token.type == :whitespace
            insert_text(token)
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tag?(token, :start_tag, "col")
            insert_html(token)
            pop_current_node
            acknowledge
            return
          end
          if tag?(token, :end_tag, "colgroup")
            unless html?(current_node, "colgroup")
              add_error(token)
              return
            end
            pop_current_node
            @mode = :in_table
            return
          end
          if tag?(token, :end_tag, "col")
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "template") || tag?(token, :end_tag, "template")
            handle_in_head(token)
            return
          end
          if token.type == :eof
            handle_in_body(token)
            return
          end
          unless html?(current_node, "colgroup")
            add_error(token)
            return
          end
          pop_current_node
          @mode = :in_table
          reprocess!
        end

        def handle_in_table_body(token)
          if tag?(token, :start_tag, "tr")
            clear_stack_to(TABLE_BODY_CONTEXT)
            insert_html(token)
            @mode = :in_row
            return
          end
          if tags?(token, :start_tag, TD_TH)
            add_error(token)
            clear_stack_to(TABLE_BODY_CONTEXT)
            insert_implied("tr")
            @mode = :in_row
            reprocess!
            return
          end
          if tags?(token, :end_tag, %w[tbody tfoot thead].to_set)
            unless has_table_scope?(down(token.name))
              add_error(token)
              return
            end
            clear_stack_to(TABLE_BODY_CONTEXT)
            pop_current_node
            @mode = :in_table
            return
          end
          if tags?(token, :start_tag, %w[caption col colgroup tbody tfoot thead].to_set) ||
              tag?(token, :end_tag, "table")
            unless has_table_scope?("tbody") || has_table_scope?("thead") || has_table_scope?("tfoot")
              add_error(token)
              return
            end
            clear_stack_to(TABLE_BODY_CONTEXT)
            pop_current_node
            @mode = :in_table
            reprocess!
            return
          end
          if tags?(token, :end_tag, %w[body caption col colgroup html td th tr].to_set)
            add_error(token)
            return
          end
          handle_in_table(token)
        end

        def handle_in_row(token)
          if tags?(token, :start_tag, TD_TH)
            clear_stack_to(TABLE_ROW_CONTEXT)
            insert_html(token)
            @mode = :in_cell
            add_formatting(SCOPE)
            return
          end
          if tag?(token, :end_tag, "tr")
            unless has_table_scope?("tr")
              add_error(token)
              return
            end
            clear_stack_to(TABLE_ROW_CONTEXT)
            pop_current_node
            @mode = :in_table_body
            return
          end
          if tags?(token, :start_tag, %w[caption col colgroup tbody tfoot thead tr].to_set) ||
              tag?(token, :end_tag, "table")
            unless has_table_scope?("tr")
              add_error(token)
              return
            end
            clear_stack_to(TABLE_ROW_CONTEXT)
            pop_current_node
            @mode = :in_table_body
            reprocess!
            return
          end
          if tags?(token, :end_tag, %w[tbody tfoot thead].to_set)
            unless has_table_scope?(down(token.name))
              add_error(token)
              return
            end
            unless has_table_scope?("tr")
              return
            end
            clear_stack_to(TABLE_ROW_CONTEXT)
            pop_current_node
            @mode = :in_table_body
            reprocess!
            return
          end
          if tags?(token, :end_tag, %w[body caption col colgroup html td th].to_set)
            add_error(token)
            return
          end
          handle_in_table(token)
        end

        def handle_in_cell(token)
          if tags?(token, :end_tag, TD_TH)
            name = down(token.name)
            unless has_table_scope?(name)
              add_error(token)
              return
            end
            close_cell(token, name)
            return
          end
          if tags?(token, :start_tag, CELL_START_CLOSE)
            unless has_table_scope?("td") || has_table_scope?("th")
              add_error(token)
              return
            end
            reprocess!
            close_current_cell(token)
            return
          end
          if tags?(token, :end_tag, %w[body caption col colgroup html].to_set)
            add_error(token)
            return
          end
          if tags?(token, :end_tag, %w[table tbody tfoot thead tr].to_set)
            unless has_table_scope?(down(token.name))
              add_error(token)
              return
            end
            reprocess!
            close_current_cell(token)
            return
          end
          handle_in_body(token)
        end

        def handle_in_select(token)
          if token.type == :null
            add_error(token)
            return
          end
          if token.type == :character || token.type == :whitespace
            insert_text(token)
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tag?(token, :start_tag, "option")
            pop_current_node if html?(current_node, "option")
            insert_html(token)
            return
          end
          if tag?(token, :start_tag, "optgroup")
            pop_current_node if html?(current_node, "option")
            pop_current_node if html?(current_node, "optgroup")
            insert_html(token)
            return
          end
          if tag?(token, :start_tag, "hr")
            pop_current_node if html?(current_node, "option")
            pop_current_node if html?(current_node, "optgroup")
            insert_html(token)
            pop_current_node
            acknowledge
            return
          end
          if tag?(token, :end_tag, "optgroup")
            if html?(current_node, "option") && @open.length >= 2 && html?(@open[-2], "optgroup")
              pop_current_node
            end
            if html?(current_node, "optgroup")
              pop_current_node
              return
            end
            add_error(token)
            return
          end
          if tag?(token, :end_tag, "option")
            if html?(current_node, "option")
              pop_current_node
              return
            end
            add_error(token)
            return
          end
          if tag?(token, :end_tag, "select")
            unless has_select_scope?("select")
              add_error(token)
              return
            end
            close_select
            return
          end
          if tag?(token, :start_tag, "select")
            add_error(token)
            close_select if has_select_scope?("select")
            return
          end
          if tags?(token, :start_tag, %w[input keygen textarea].to_set)
            add_error(token)
            unless has_select_scope?("select")
              return
            end
            close_select
            reprocess!
            return
          end
          if tags?(token, :start_tag, %w[script template].to_set) || tag?(token, :end_tag, "template")
            handle_in_head(token)
            return
          end
          if token.type == :eof
            handle_in_body(token)
            return
          end
          add_error(token)
        end

        def handle_in_select_in_table(token)
          if tags?(token, :start_tag, SELECT_TABLE)
            add_error(token)
            close_select
            reprocess!
            return
          end
          if tags?(token, :end_tag, SELECT_TABLE)
            add_error(token)
            unless has_table_scope?(down(token.name))
              return
            end
            close_select
            reprocess!
            return
          end
          handle_in_select(token)
        end

        def handle_in_template(token)
          case token.type
          when :whitespace, :character, :comment, :null, :doctype
            handle_in_body(token)
            return
          end
          if tags?(token, :start_tag, HEAD_ELS) || tag?(token, :end_tag, "template")
            handle_in_head(token)
            return
          end
          if tags?(token, :start_tag, %w[caption colgroup tbody tfoot thead].to_set)
            @template_modes.pop
            @template_modes << :in_table
            @mode = :in_table
            reprocess!
            return
          end
          if tag?(token, :start_tag, "col")
            @template_modes.pop
            @template_modes << :in_column_group
            @mode = :in_column_group
            reprocess!
            return
          end
          if tag?(token, :start_tag, "tr")
            @template_modes.pop
            @template_modes << :in_table_body
            @mode = :in_table_body
            reprocess!
            return
          end
          if tags?(token, :start_tag, TD_TH)
            @template_modes.pop
            @template_modes << :in_row
            @mode = :in_row
            reprocess!
            return
          end
          if token.type == :start_tag
            @template_modes.pop
            @template_modes << :in_body
            @mode = :in_body
            reprocess!
            return
          end
          if token.type == :end_tag
            add_error(token)
            return
          end
          return if token.type != :eof
          return unless has_open?("template")

          add_error(token)
          pop_through_html("template")
          clear_formatting
          @template_modes.pop
          reset_mode
          reprocess!
        end

        def handle_after_body(token)
          if token.type == :whitespace || tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if token.type == :comment
            append_comment(@root, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :end_tag, "html")
            if @fragment_ctx
              add_error(token)
              return
            end
            @mode = :after_after_body
            return
          end
          return if token.type == :eof

          add_error(token)
          @mode = :in_body
          reprocess!
        end

        def handle_in_frameset(token)
          if token.type == :whitespace
            insert_text(token)
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tag?(token, :start_tag, "frameset")
            insert_html(token)
            return
          end
          if tag?(token, :end_tag, "frameset")
            if html?(current_node, "html")
              add_error(token)
              return
            end
            pop_current_node
            if !@fragment_ctx && !html?(current_node, "frameset")
              @mode = :after_frameset
            end
            return
          end
          if tag?(token, :start_tag, "frame")
            insert_html(token)
            pop_current_node
            acknowledge
            return
          end
          if tag?(token, :start_tag, "noframes")
            handle_in_head(token)
            return
          end
          if token.type == :eof
            add_error(token) unless html?(current_node, "html")
            return
          end
          add_error(token)
        end

        def handle_after_frameset(token)
          if token.type == :whitespace
            insert_text(token)
            return
          end
          if token.type == :comment
            append_comment(current_node, token)
            return
          end
          if token.type == :doctype
            add_error(token)
            return
          end
          if tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          if tag?(token, :end_tag, "html")
            @mode = :after_after_frameset
            return
          end
          if tag?(token, :start_tag, "noframes")
            handle_in_head(token)
            return
          end
          return if token.type == :eof

          add_error(token)
        end

        def handle_after_after_body(token)
          if token.type == :comment
            append_comment(@document, token)
            return
          end
          if token.type == :doctype || token.type == :whitespace || tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          return if token.type == :eof

          add_error(token)
          @mode = :in_body
          reprocess!
        end

        def handle_after_after_frameset(token)
          if token.type == :comment
            append_comment(@document, token)
            return
          end
          if token.type == :doctype || token.type == :whitespace || tag?(token, :start_tag, "html")
            handle_in_body(token)
            return
          end
          return if token.type == :eof
          if tag?(token, :start_tag, "noframes")
            handle_in_head(token)
            return
          end
          add_error(token)
        end

        def handle_foreign(token)
          case token.type
          when :null
            add_error(token)
            insert_text(token, replacement: true)
            return
          when :whitespace
            insert_text(token)
            return
          when :cdata, :character
            insert_text(token)
            frameset_not_ok
            return
          when :comment
            append_comment(current_node, token)
            return
          when :doctype
            add_error(token)
            return
          end
          if tags?(token, :start_tag, FOREIGN_BREAK_START) ||
              (tag?(token, :start_tag, "font") && (has_attr?(token, "color") || has_attr?(token, "face") || has_attr?(token, "size"))) ||
              tags?(token, :end_tag, %w[br p].to_set)
            add_error(token)
            while (node = current_node) &&
                node.namespace != :html && !mathml_ip?(node) && !html_ip?(node)
              pop_current_node
            end
            handle_html(token)
            return
          end
          if token.type == :start_tag
            namespace = adjusted_current.namespace
            insert_foreign(token, namespace, adjust_tag: true)
            return
          end
          node = current_node
          add_error(token) unless node && down(node.name) == down(token.name)
          index = @open.length - 1
          while index > 0
            if node && down(node.name) == down(token.name)
              loop do
                popped = pop_current_node
                break if popped.equal?(node) || popped.nil?
              end
              return
            end
            index -= 1
            node = @open[index]
            break if node.namespace == :html
          end
          return if index == 0

          handle_html(token)
        end
      end
    end
  end
end
