# Vernier Profile

## Summary

| Metric | Value |
|--------|-------|
| Mode | wall |
| Duration | 2.01 seconds |
| Total Samples | 8671 |
| Total Unique Samples | 220 |
| Threads | 1 |
| Weight Unit | samples |
| PID | 991670 |

## Top Hotspots

### By Self Time

| Rank | Self % | Total % | Function | Location |
|------|--------|---------|----------|----------|
| 1 | 13.9% | 13.9% | `String#byteindex` | &lt;cfunc&gt;:0 |
| 2 | 13.0% | 13.0% | `StringScanner#skip` | &lt;cfunc&gt;:0 |
| 3 | 12.3% | 16.8% | `Nokogiri::Pure::Parser#flat_read_attrs` | lib/nokogiri/pure/parser.rb:1599 |
| 4 | 9.7% | 94.9% | `Nokogiri::Pure::Parser#try_flat_tree` | lib/nokogiri/pure/parser.rb:138 |
| 5 | 8.3% | 10.6% | `Nokogiri::Pure::FlatTree#add_text_node` | lib/nokogiri/pure/flat\_tree.rb:510 |
| 6 | 7.8% | 36.8% | `Nokogiri::Pure::Parser#flat_add_tag` | lib/nokogiri/pure/parser.rb:1462 |
| 7 | 7.2% | 8.2% | `Nokogiri::Pure::FlatTree#add_element` | lib/nokogiri/pure/flat\_tree.rb:52 |
| 8 | 3.5% | 3.5% | `Nokogiri::Pure::FlatTree#add_attr` | lib/nokogiri/pure/flat\_tree.rb:82 |
| 9 | 3.2% | 3.2% | `Nokogiri::Pure::FlatTree#link` | lib/nokogiri/pure/flat\_tree.rb:532 |
| 10 | 2.8% | 3.0% | `Nokogiri::Pure::Parser#decode_fast_attr` | lib/nokogiri/pure/parser.rb:1810 |
| 11 | 2.4% | 3.0% | `Nokogiri::Pure::Parser#split_name` | lib/nokogiri/pure/parser.rb:2979 |
| 12 | 1.7% | 12.1% | `Array#each` | &lt;internal:array&gt;:219 |
| 13 | 1.6% | 1.6% | `Nokogiri::Pure::FlatTree#raw_eq?` | lib/nokogiri/pure/flat\_tree.rb:226 |
| 14 | 1.2% | 2.6% | `Nokogiri::Pure::Parser#plain_entities?` | lib/nokogiri/pure/parser.rb:1661 |
| 15 | 0.9% | 3.1% | `Nokogiri::Pure::Parser#flat_newline_table` | lib/nokogiri/pure/parser.rb:1398 |
| 16 | 0.6% | 1.7% | `Class#new` | &lt;cfunc&gt;:0 |
| 17 | 0.5% | 0.5% | `String#include?` | &lt;cfunc&gt;:0 |
| 18 | 0.5% | 0.5% | `StringScanner#pos=` | &lt;cfunc&gt;:0 |
| 19 | 0.4% | 0.4% | `Nokogiri::Pure::FlatTree#initialize` | lib/nokogiri/pure/flat\_tree.rb:23 |
| 20 | 0.4% | 0.4% | `String#start_with?` | &lt;cfunc&gt;:0 |
| 21 | 0.4% | 0.4% | `Nokogiri::Pure::Parser#name_start_byte?` | lib/nokogiri/pure/parser.rb:2971 |
| 22 | 0.3% | 10.9% | `Nokogiri::Pure::FlatTree#add_text_range` | lib/nokogiri/pure/flat\_tree.rb:74 |
| 23 | 0.3% | 0.3% | `Nokogiri::Pure::Parser#flat_line` | lib/nokogiri/pure/parser.rb:1408 |
| 24 | 0.3% | 0.3% | `Array#pop` | &lt;cfunc&gt;:0 |
| 25 | 0.3% | 0.5% | `Nokogiri::Pure::Parser#name_byte?` | lib/nokogiri/pure/parser.rb:2975 |
| 26 | 0.3% | 0.8% | `Nokogiri::XML::Document.new` | lib/nokogiri/pure/dom.rb:1048 |
| 27 | 0.3% | 1.4% | `Nokogiri::Pure::Parser#read_attributes` | lib/nokogiri/pure/parser.rb:2723 |
| 28 | 0.3% | 0.3% | `String#delete_prefix!` | &lt;cfunc&gt;:0 |
| 29 | 0.2% | 0.2% | `StringScanner#pos` | &lt;cfunc&gt;:0 |
| 30 | 0.2% | 0.2% | `Regexp#match` | &lt;cfunc&gt;:0 |

### By Total Time

| Rank | Total % | Self % | Function | Location |
|------|--------|---------|----------|----------|
| 1 | 100.0% | 0.0% | `<main>` | /tmp/profile\_hot.rb:0 |
| 2 | 100.0% | 0.0% | `block in <main>` | /tmp/profile\_hot.rb:20 |
| 3 | 100.0% | 0.0% | `block (2 levels) in <main>` | /tmp/profile\_hot.rb:33 |
| 4 | 100.0% | 0.0% | `Vernier.profile` | gem:vernier-1.11.0:lib/vernier.rb:24 |
| 5 | 100.0% | 0.0% | `Hash#each` | &lt;cfunc&gt;:0 |
| 6 | 99.9% | 0.0% | `Nokogiri.XML` | lib/nokogiri/xml.rb:6 |
| 7 | 99.9% | 0.1% | `Nokogiri::XML::Document.parse` | lib/nokogiri/xml/document.rb:56 |
| 8 | 99.8% | 0.1% | `Nokogiri::XML::Document.read_memory` | lib/nokogiri/pure/dom.rb:1068 |
| 9 | 98.1% | 0.0% | `Nokogiri::Pure::Parser.parse` | lib/nokogiri/pure/parser.rb:28 |
| 10 | 97.4% | 0.1% | `Nokogiri::Pure::Parser#parse_document` | lib/nokogiri/pure/parser.rb:73 |
| 11 | 95.6% | 0.1% | `Nokogiri::Pure::Parser#parse_loop` | lib/nokogiri/pure/parser.rb:108 |
| 12 | 94.9% | 9.7% | `Nokogiri::Pure::Parser#try_flat_tree` | lib/nokogiri/pure/parser.rb:138 |
| 13 | 36.8% | 7.8% | `Nokogiri::Pure::Parser#flat_add_tag` | lib/nokogiri/pure/parser.rb:1462 |
| 14 | 16.8% | 12.3% | `Nokogiri::Pure::Parser#flat_read_attrs` | lib/nokogiri/pure/parser.rb:1599 |
| 15 | 13.9% | 13.9% | `String#byteindex` | &lt;cfunc&gt;:0 |
| 16 | 13.0% | 13.0% | `StringScanner#skip` | &lt;cfunc&gt;:0 |
| 17 | 12.1% | 1.7% | `Array#each` | &lt;internal:array&gt;:219 |
| 18 | 10.9% | 0.3% | `Nokogiri::Pure::FlatTree#add_text_range` | lib/nokogiri/pure/flat\_tree.rb:74 |
| 19 | 10.6% | 8.3% | `Nokogiri::Pure::FlatTree#add_text_node` | lib/nokogiri/pure/flat\_tree.rb:510 |
| 20 | 8.2% | 7.2% | `Nokogiri::Pure::FlatTree#add_element` | lib/nokogiri/pure/flat\_tree.rb:52 |
| 21 | 3.5% | 3.5% | `Nokogiri::Pure::FlatTree#add_attr` | lib/nokogiri/pure/flat\_tree.rb:82 |
| 22 | 3.2% | 3.2% | `Nokogiri::Pure::FlatTree#link` | lib/nokogiri/pure/flat\_tree.rb:532 |
| 23 | 3.1% | 0.9% | `Nokogiri::Pure::Parser#flat_newline_table` | lib/nokogiri/pure/parser.rb:1398 |
| 24 | 3.0% | 2.4% | `Nokogiri::Pure::Parser#split_name` | lib/nokogiri/pure/parser.rb:2979 |
| 25 | 3.0% | 2.8% | `Nokogiri::Pure::Parser#decode_fast_attr` | lib/nokogiri/pure/parser.rb:1810 |
| 26 | 2.6% | 1.2% | `Nokogiri::Pure::Parser#plain_entities?` | lib/nokogiri/pure/parser.rb:1661 |
| 27 | 1.7% | 0.1% | `Nokogiri::Pure::Parser#read_xml_declaration` | lib/nokogiri/pure/parser.rb:1941 |
| 28 | 1.7% | 0.6% | `Class#new` | &lt;cfunc&gt;:0 |
| 29 | 1.6% | 1.6% | `Nokogiri::Pure::FlatTree#raw_eq?` | lib/nokogiri/pure/flat\_tree.rb:226 |
| 30 | 1.4% | 0.3% | `Nokogiri::Pure::Parser#read_attributes` | lib/nokogiri/pure/parser.rb:2723 |

## Threads

### /tmp/profile\_hot.rb

| Property | Value |
|----------|-------|
| TID | 991670 |
| Main Thread | yes |
| Samples | 8671 |
| Total Weight | 9391 |

## Hot Files

### lib/nokogiri/pure/parser.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 39.4% | 39.4% | `_source unavailable_` |
| 1492 | 0.1% | 4.5% | `attrs.each do \|attr_name, value\|` |
| 208 | 0.1% | 0.1% | `(byte >= 65 && byte <= 90) \|\| (byte >= 97 && byte <= 122)...` |
| 1529 | 0.1% | 7.9% | `plain.each do \|attr_name, value\|` |
| 206 | 0.1% | 0.1% | `byte = string.getbyte(index)` |

### lib/nokogiri/pure/flat\_tree.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 24.9% | 24.9% | `_source unavailable_` |
| 75 | 0.0% | 10.6% | `add_text_node(parent, line, off, len, nil)` |
| 496 | 0.0% | 0.0% | `state.instance_variable_set(:@flat_attrs, false)` |
| 378 | 0.0% | 0.5% | `node = wrapper(index)` |
| 528 | 0.0% | 2.2% | `link(parent, index)` |

