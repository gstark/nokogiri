# frozen_string_literal: true

module Nokogiri
  module Pure
    module Support
      def self.memsize_of_document(document)
        size = 176
        walk = lambda do |node|
          return unless node.respond_to?(:pure) && node.pure

          size += 80 + node.name.to_s.bytesize
          if node.respond_to?(:text?) && (node.text? || node.cdata?)
            size += node.pure.content.to_s.bytesize
          end
          if node.respond_to?(:element?) && node.element?
            node.pure.attributes.each do |attr|
              size += 48 + attr.name.to_s.bytesize + attr.value.to_s.bytesize
            end
          end
          node.pure.children.each { |child| walk.call(child) }
        end
        walk.call(document)
        size
      end
    end

    # Report document tree bytes through ObjectSpace.memsize_of.
    # The C extension does this with a typed-data dsize callback.
    module ObjectSpaceMemsize
      def memsize_of(object)
        if defined?(::Nokogiri::XML::Document) && object.is_a?(::Nokogiri::XML::Document)
          return ::Nokogiri::Pure::Support.memsize_of_document(object)
        end

        super
      end
    end
  end
end

ObjectSpace.singleton_class.prepend(Nokogiri::Pure::ObjectSpaceMemsize)
