# frozen_string_literal: true

require_relative "config"

module Autoresearch
  module Canon
    module_function

    def read_corpus(name)
      File.read(File.join(CORPUS_DIR, name), encoding: "UTF-8")
    end

    def parse_xml(string)
      Nokogiri::XML(string)
    end

    def parse_html(string)
      Nokogiri::HTML4(string)
    end

    # Element order, namespaces, attributes, and direct text.
    # Whitespace inside text is kept. This is the XML compatibility record.
    def xml_sig(doc)
      lines = []
      doc.xpath("//*").each do |el|
        href = el.namespace ? el.namespace.href.to_s : ""
        attrs = el.attribute_nodes.map { |attr|
          attr_href = attr.namespace ? attr.namespace.href.to_s : ""
          "#{attr_href}\t#{attr.name}\t#{attr.value}"
        }
        attrs.sort!
        text = +""
        el.xpath("./text()").each { |node| text << node.text }
        lines << "#{href}\t#{el.name}\t#{attrs.join("\x1e")}\t#{text}"
      end
      lines.join("\n")
    end

    # Names, attributes, and direct text with whitespace removed.
    # Used on a document produced by to_xml, where indent can differ.
    def xml_data_sig(doc)
      lines = []
      doc.xpath("//*").each do |el|
        href = el.namespace ? el.namespace.href.to_s : ""
        attrs = el.attribute_nodes.map { |attr|
          attr_href = attr.namespace ? attr.namespace.href.to_s : ""
          "#{attr_href}\t#{attr.name}\t#{attr.value}"
        }
        attrs.sort!
        text = +""
        el.xpath("./text()").each { |node| text << node.text }
        text.gsub!(/\s+/, "")
        lines << "#{href}\t#{el.name}\t#{attrs.join("\x1e")}\t#{text}"
      end
      lines.join("\n")
    end

    # Fields that already match libxml on the HTML corpus.
    # The pure HTML parser does not decode HTML named entities such as
    # &raquo;. Text is compared after non-ASCII characters are removed.
    # URLs stay exact.
    def html_proj(doc)
      lines = []
      lines << "title\t#{fold_text(doc.at_css("title")&.text)}"
      doc.css("h1").each { |node| lines << "h1\t#{fold_text(node.text)}" }
      doc.css("h2").each { |node| lines << "h2\t#{fold_text(node.text)}" }
      doc.css("a").each { |node| lines << "a\t#{node["href"]}\t#{fold_text(node.text)}" }
      doc.css("img").each { |node| lines << "img\t#{node["src"]}\t#{fold_text(node["alt"])}" }
      lines.join("\n")
    end

    def fold_text(text)
      text.to_s.gsub(/[^\t\n\r\x20-\x7E]/, "").gsub(/[ \t]+/, " ").strip
    end

    def xpath_names(doc)
      doc.xpath("//xmlns:item/xmlns:name", "xmlns" => NS_BENCH).map(&:text).join("\n")
    end

    def css_names(doc)
      doc.css("item > name").map(&:text).join("\n")
    end

    def edit_record(doc)
      node = doc.at_xpath("(//xmlns:item/xmlns:name)[1]", "xmlns" => NS_BENCH)
      price = doc.at_xpath("(//xmlns:item/xmlns:price)[1]", "xmlns" => NS_BENCH)
      original = node.text
      node.content = "bench"
      changed = node.text
      node.content = original
      restored = node.text
      "#{original}\n#{changed}\n#{restored}\n#{price.text}"
    end
  end
end
