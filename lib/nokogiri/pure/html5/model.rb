# frozen_string_literal: true

module Nokogiri
  module Pure
    module Html5
      HTML_NS = "http://www.w3.org/1999/xhtml"
      SVG_NS = "http://www.w3.org/2000/svg"
      MATHML_NS = "http://www.w3.org/1998/Math/MathML"
      XLINK_NS = "http://www.w3.org/1999/xlink"
      XML_NS = "http://www.w3.org/XML/1998/namespace"
      XMLNS_NS = "http://www.w3.org/2000/xmlns/"

      module Ns
        HTML = :html
        SVG = :svg
        MATHML = :mathml
      end

      # One HTML token. Attribute rows are [name, value].
      class Token
        attr_accessor :type, :name, :data, :public_id, :system_id,
          :has_public_id, :has_system_id, :force_quirks, :attrs,
          :self_closing, :line, :column, :byte_offset, :original

        def initialize(**kwargs)
          @attrs = []
          @has_public_id = false
          @has_system_id = false
          @force_quirks = false
          @self_closing = false
          @original = ""
          @data = ""
          kwargs.each { |key, value| public_send(:"#{key}=", value) }
        end
      end

      # Intermediate tree node. The DOM adapter turns these into Nokogiri nodes.
      class Node
        attr_accessor :type, :name, :namespace, :attrs, :children, :parent,
          :quirks_mode, :doctype_name, :public_id, :system_id, :has_doctype,
          :line, :content

        def initialize(type)
          @type = type
          @attrs = []
          @children = []
          @namespace = Ns::HTML
          @has_doctype = false
          @quirks_mode = 0
        end

        def element?
          type == :element
        end
      end

      class ParseError
        attr_accessor :code, :message, :line, :column, :byte_offset

        def initialize(**kwargs)
          kwargs.each { |key, value| public_send(:"#{key}=", value) }
        end
      end

      # Records parse errors up to max_errors. A negative limit records every error.
      class ErrorLog
        attr_reader :errors

        def initialize(max_errors)
          @max_errors = max_errors
          @errors = []
        end

        def add(code:, message:, line:, column:, byte_offset:)
          return if @max_errors.between?(0, @errors.length)

          @errors << ParseError.new(
            code: code,
            message: message,
            line: line,
            column: column,
            byte_offset: byte_offset
          )
        end
      end
    end
  end
end
