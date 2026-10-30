# frozen_string_literal: true

require "uri"

module Nokogiri
  module Pure
    # XML Inclusions (XInclude) for the pure Ruby backend.
    module XInclude
      NS_2001 = "http://www.w3.org/2001/XInclude"
      NS_2003 = "http://www.w3.org/2003/XInclude"

      module_function

      def apply(node, _options)
        collect(node).each { |include_node| replace(include_node) }
        node
      end

      def collect(node, list = [])
        if include?(node)
          list << node
          return list
        end

        children(node).each { |child| collect(child, list) }
        list
      end

      def include?(node)
        node.element? && node.name == "include" && xinclude_ns?(node)
      end

      def xinclude_ns?(node)
        href = node.namespace&.href
        href == NS_2001 || href == NS_2003
      end

      def children(node)
        return [] unless node.respond_to?(:pure)

        node.pure.children
      end

      def replace(node)
        parent = node.parent
        raise "no parent" unless parent

        nodes = load_nodes(node)
        nodes.each { |child| node.add_previous_sibling(child) }
        node.unlink
      end

      def load_nodes(node)
        href = node["href"]
        kind = node["parse"] || "xml"
        read_included(node, href, kind)
      rescue
        fallback = children(node).find { |child| child.element? && child.name == "fallback" && xinclude_ns?(child) }
        raise unless fallback

        children(fallback).dup
      end

      def read_included(node, href, kind)
        path = resolve(node, href)
        body = File.read(path)
        if kind == "text"
          [XML::Text.new(body, node.document)]
        else
          included = XML::Document.parse(body)
          root = included.root
          raise "empty include" unless root

          [root]
        end
      end

      def resolve(node, href)
        raise "missing href" if href.nil? || href.empty?

        if href.start_with?("file:")
          URI.parse(href).path
        else
          base = node.document&.url
          base = URI.parse(base).path if base&.start_with?("file:")
          return href unless base

          File.expand_path(href, File.dirname(base))
        end
      end
    end
  end
end
