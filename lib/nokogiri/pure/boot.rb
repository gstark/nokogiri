# frozen_string_literal: true

# Class shells for the pure backend.
#
# lib/nokogiri/**/*.rb reopens these classes. The shells must exist first,
# and the methods those files alias must already be defined.
module Nokogiri
  PURE_RUBY = true
  PACKAGED_LIBRARIES = false
  PRECOMPILED_LIBRARIES = false
  LIBXML2_PATCHES = [].freeze
  LIBXSLT_PATCHES = [].freeze
  # Present so test/xml/test_schema.rb can load. Do not define
  # LIBXML_COMPILED_VERSION: that constant turns uses_libxml? on.
  LIBXML_HTTP_ENABLED = false

  class SyntaxError < ::StandardError
  end

  class EncodingHandler
    def self.[](name)
      return if name.nil?

      canonical = aliases[name.to_s]
      return if canonical.nil?

      new(canonical)
    end

    def self.alias(name, alias_name)
      aliases[alias_name.to_s] = name.to_s
    end

    def self.delete(name)
      aliases.delete(name.to_s)
    end

    def self.clear_aliases!
      aliases.clear
    end

    def self.aliases
      @aliases ||= {}
    end

    def initialize(name)
      @name = name
    end

    attr_reader :name
  end

  module XML
    class Node
    end

    class Element < Node
    end

    class CharacterData < Node
    end

    class Text < CharacterData
    end

    class Comment < CharacterData
    end

    class CDATA < Text
    end

    class Attr < Node
    end

    class DocumentFragment < Node
    end

    class Document < Node
    end

    class DTD < Node
    end

    class EntityDecl < Node
    end

    class EntityReference < Node
    end

    class ProcessingInstruction < Node
    end

    class ElementDecl < Node
    end

    class AttributeDecl < Node
    end

    class ElementContent
    end

    class Namespace
    end

    class NodeSet
    end

    class XPathContext
    end

    class Schema
    end

    class RelaxNG < Schema
    end

    class Reader
    end

    class SyntaxError < ::Nokogiri::SyntaxError
    end

    module XPath
      class SyntaxError < XML::SyntaxError
      end
    end

    module SAX
      class Parser
        def initialize_native
        end
      end

      class ParserContext
      end

      class PushParser
      end
    end
  end

  module HTML4
    class Document < XML::Document
    end

    class DocumentFragment < XML::DocumentFragment
    end

    class ElementDescription
    end

    class EntityLookup
    end

    module SAX
      class Parser < XML::SAX::Parser
      end

      class ParserContext < XML::SAX::ParserContext
      end

      class PushParser < XML::SAX::PushParser
      end
    end
  end

  module XSLT
    class Stylesheet
    end
  end

  module Gumbo
  end
end

require_relative "dom"
require_relative "flat_tree"
require_relative "parser"
require_relative "serializer"
require_relative "xpath"
require_relative "sax"
require_relative "reader"
require_relative "schema"
require_relative "relaxng"
require_relative "xslt"
require_relative "c14n"
require_relative "memsize"
