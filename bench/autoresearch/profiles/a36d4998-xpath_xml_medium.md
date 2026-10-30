# Vernier Profile

## Summary

| Metric | Value |
|--------|-------|
| Mode | wall |
| Duration | 2.01 seconds |
| Total Samples | 6857 |
| Total Unique Samples | 97 |
| Threads | 1 |
| Weight Unit | samples |
| PID | 991670 |

## Top Hotspots

### By Self Time

| Rank | Self % | Total % | Function | Location |
|------|--------|---------|----------|----------|
| 1 | 50.2% | 50.2% | `Nokogiri::Pure::FlatTree#local_eq?` | lib/nokogiri/pure/flat\_tree.rb:573 |
| 2 | 17.8% | 19.5% | `Nokogiri::XML::Node#collect_text` | lib/nokogiri/pure/dom.rb:979 |
| 3 | 8.3% | 61.0% | `Nokogiri::Pure::FlatTree#named_children_in` | lib/nokogiri/pure/flat\_tree.rb:260 |
| 4 | 5.2% | 30.7% | `Nokogiri::XML::NodeSet#each` | lib/nokogiri/xml/node\_set.rb:233 |
| 5 | 2.5% | 4.0% | `Nokogiri::XML::NodeSet#push` | lib/nokogiri/pure/dom.rb:1363 |
| 6 | 2.3% | 30.7% | `Integer#upto` | &lt;cfunc&gt;:0 |
| 7 | 1.7% | 1.7% | `Nokogiri::Pure::FlatTree#href_is?` | lib/nokogiri/pure/flat\_tree.rb:600 |
| 8 | 1.6% | 2.1% | `Nokogiri::XML::NodeSet#[]` | lib/nokogiri/pure/dom.rb:1375 |
| 9 | 1.5% | 7.9% | `Array#each` | &lt;internal:array&gt;:219 |
| 10 | 0.8% | 0.8% | `Nokogiri::XML::Node#pure` | lib/nokogiri/pure/dom.rb:165 |
| 11 | 0.8% | 20.9% | `Nokogiri::XML::Node#content` | lib/nokogiri/pure/dom.rb:245 |
| 12 | 0.8% | 0.8% | `Nokogiri::Pure::FlatTree#wrapper` | lib/nokogiri/pure/flat\_tree.rb:468 |
| 13 | 0.8% | 1.0% | `Nokogiri::XML::Node#document` | lib/nokogiri/pure/dom.rb:214 |
| 14 | 0.6% | 0.6% | `String#gsub` | &lt;cfunc&gt;:0 |
| 15 | 0.6% | 0.9% | `Nokogiri::XML::Node#node_type` | lib/nokogiri/pure/dom.rb:201 |
| 16 | 0.5% | 5.2% | `Nokogiri::XML::NodeSet#initialize` | lib/nokogiri/xml/node\_set.rb:22 |
| 17 | 0.4% | 0.4% | `Regexp#match` | &lt;cfunc&gt;:0 |
| 18 | 0.3% | 0.3% | `Nokogiri::Pure::FlatState#children` | lib/nokogiri/pure/flat\_tree.rb:823 |
| 19 | 0.3% | 0.3% | `Array#[]` | &lt;cfunc&gt;:0 |
| 20 | 0.3% | 0.4% | `Nokogiri::XML::Searchable#extract_params` | lib/nokogiri/xml/searchable.rb:223 |
| 21 | 0.2% | 100.0% | `block (2 levels) in <main>` | /tmp/profile\_hot.rb:33 |
| 22 | 0.2% | 0.2% | `MatchData#[]` | &lt;cfunc&gt;:0 |
| 23 | 0.2% | 0.2% | `Nokogiri::XML::Document#decorate` | lib/nokogiri/xml/document.rb:410 |
| 24 | 0.2% | 100.0% | `block in <main>` | /tmp/profile\_hot.rb:23 |
| 25 | 0.2% | 0.2% | `Nokogiri::XML::NodeSet#members` | lib/nokogiri/pure/dom.rb:1420 |
| 26 | 0.2% | 0.2% | `Nokogiri::XML::NodeSet#wrap_subset` | lib/nokogiri/pure/dom.rb:1424 |
| 27 | 0.2% | 0.2% | `Nokogiri::XML::NodeSet#member!` | lib/nokogiri/pure/dom.rb:1436 |
| 28 | 0.2% | 61.9% | `Nokogiri::Pure::XPath.fast_nodes` | lib/nokogiri/pure/xpath.rb:59 |
| 29 | 0.1% | 0.2% | `Enumerable#find` | &lt;cfunc&gt;:0 |
| 30 | 0.1% | 67.3% | `Nokogiri::Pure::XPath.evaluate` | lib/nokogiri/pure/xpath.rb:20 |

### By Total Time

| Rank | Total % | Self % | Function | Location |
|------|--------|---------|----------|----------|
| 1 | 100.0% | 0.2% | `block in <main>` | /tmp/profile\_hot.rb:23 |
| 2 | 100.0% | 0.2% | `block (2 levels) in <main>` | /tmp/profile\_hot.rb:33 |
| 3 | 100.0% | 0.0% | `Vernier.profile` | gem:vernier-1.11.0:lib/vernier.rb:24 |
| 4 | 100.0% | 0.1% | `Hash#each` | &lt;cfunc&gt;:0 |
| 5 | 100.0% | 0.0% | `<main>` | /tmp/profile\_hot.rb:0 |
| 6 | 69.0% | 0.1% | `Nokogiri::XML::Searchable#xpath` | lib/nokogiri/xml/searchable.rb:188 |
| 7 | 68.5% | 0.0% | `Nokogiri::XML::Searchable#xpath_internal` | lib/nokogiri/xml/searchable.rb:261 |
| 8 | 68.5% | 0.1% | `Nokogiri::XML::Searchable#xpath_impl` | lib/nokogiri/xml/searchable.rb:276 |
| 9 | 67.3% | 0.0% | `Nokogiri::XML::XPathContext#evaluate` | lib/nokogiri/pure/xpath.rb:1901 |
| 10 | 67.3% | 0.1% | `Nokogiri::Pure::XPath.evaluate` | lib/nokogiri/pure/xpath.rb:20 |
| 11 | 61.9% | 0.2% | `Nokogiri::Pure::XPath.fast_nodes` | lib/nokogiri/pure/xpath.rb:59 |
| 12 | 61.1% | 0.0% | `Nokogiri::Pure::XPath.qnamed_children` | lib/nokogiri/pure/xpath.rb:224 |
| 13 | 61.0% | 8.3% | `Nokogiri::Pure::FlatTree#named_children_in` | lib/nokogiri/pure/flat\_tree.rb:260 |
| 14 | 50.2% | 50.2% | `Nokogiri::Pure::FlatTree#local_eq?` | lib/nokogiri/pure/flat\_tree.rb:573 |
| 15 | 30.7% | 5.2% | `Nokogiri::XML::NodeSet#each` | lib/nokogiri/xml/node\_set.rb:233 |
| 16 | 30.7% | 2.3% | `Integer#upto` | &lt;cfunc&gt;:0 |
| 17 | 20.9% | 0.8% | `Nokogiri::XML::Node#content` | lib/nokogiri/pure/dom.rb:245 |
| 18 | 19.5% | 17.8% | `Nokogiri::XML::Node#collect_text` | lib/nokogiri/pure/dom.rb:979 |
| 19 | 7.9% | 1.5% | `Array#each` | &lt;internal:array&gt;:219 |
| 20 | 5.2% | 0.0% | `Class#new` | &lt;cfunc&gt;:0 |
| 21 | 5.2% | 0.5% | `Nokogiri::XML::NodeSet#initialize` | lib/nokogiri/xml/node\_set.rb:22 |
| 22 | 4.0% | 2.5% | `Nokogiri::XML::NodeSet#push` | lib/nokogiri/pure/dom.rb:1363 |
| 23 | 2.1% | 1.6% | `Nokogiri::XML::NodeSet#[]` | lib/nokogiri/pure/dom.rb:1375 |
| 24 | 1.7% | 1.7% | `Nokogiri::Pure::FlatTree#href_is?` | lib/nokogiri/pure/flat\_tree.rb:600 |
| 25 | 1.0% | 0.8% | `Nokogiri::XML::Node#document` | lib/nokogiri/pure/dom.rb:214 |
| 26 | 0.9% | 0.6% | `Nokogiri::XML::Node#node_type` | lib/nokogiri/pure/dom.rb:201 |
| 27 | 0.8% | 0.8% | `Nokogiri::XML::Node#pure` | lib/nokogiri/pure/dom.rb:165 |
| 28 | 0.8% | 0.8% | `Nokogiri::Pure::FlatTree#wrapper` | lib/nokogiri/pure/flat\_tree.rb:468 |
| 29 | 0.6% | 0.6% | `String#gsub` | &lt;cfunc&gt;:0 |
| 30 | 0.4% | 0.3% | `Nokogiri::XML::Searchable#extract_params` | lib/nokogiri/xml/searchable.rb:223 |

## Threads

### /tmp/profile\_hot.rb

| Property | Value |
|----------|-------|
| TID | 991670 |
| Main Thread | yes |
| Samples | 6857 |
| Total Weight | 8623 |

## Hot Files

### lib/nokogiri/pure/flat\_tree.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 60.8% | 60.8% | `_source unavailable_` |
| 267 | 0.2% | 44.3% | `if @type[i] == ELEMENT && local_eq?(i, child_name, child_...` |
| 270 | 0.1% | 0.9% | `out << wrapper(i)` |
| 269 | 0.1% | 7.9% | `if parent >= 0 && @type[parent] == ELEMENT && local_eq?(p...` |
| 274 | 0.1% | 0.1% | `i += 1` |

### lib/nokogiri/pure/dom.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 25.5% | 25.5% | `_source unavailable_` |
| 250 | 0.0% | 19.6% | `collect_text(pure)` |
| 981 | 0.0% | 2.9% | `state.children.each do \|child\|` |
| 1376 | 0.0% | 0.5% | `wrap_subset(members.[](*args))` |
| 1364 | 0.0% | 0.2% | `member!(node)` |

### lib/nokogiri/xml/node\_set.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 5.5% | 5.5% | `_source unavailable_` |
| 237 | 0.2% | 23.4% | `yield self[x]` |
| 25 | 0.0% | 9.1% | `list.each { \|x\| self << x }` |
| 22 | 0.0% | 0.0% | `def initialize(document, list = [])` |
| 236 | 0.0% | 30.7% | `0.upto(length - 1) do \|x\|` |

