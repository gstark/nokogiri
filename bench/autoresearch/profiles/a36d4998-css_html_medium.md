# Vernier Profile

## Summary

| Metric | Value |
|--------|-------|
| Mode | wall |
| Duration | 2.00 seconds |
| Total Samples | 8517 |
| Total Unique Samples | 135 |
| Threads | 1 |
| Weight Unit | samples |
| PID | 991670 |

## Top Hotspots

### By Self Time

| Rank | Self % | Total % | Function | Location |
|------|--------|---------|----------|----------|
| 1 | 27.7% | 32.2% | `Enumerable#find` | &lt;cfunc&gt;:0 |
| 2 | 12.9% | 20.3% | `Nokogiri::Pure::FlatTree#named` | lib/nokogiri/pure/flat\_tree.rb:243 |
| 3 | 12.0% | 70.3% | `Nokogiri::XML::NodeSet#each` | lib/nokogiri/xml/node\_set.rb:233 |
| 4 | 9.2% | 11.9% | `Nokogiri::XML::Node#collect_text` | lib/nokogiri/pure/dom.rb:979 |
| 5 | 7.1% | 7.1% | `Nokogiri::Pure::FlatTree#local_eq?` | lib/nokogiri/pure/flat\_tree.rb:573 |
| 6 | 3.9% | 70.3% | `Integer#upto` | &lt;cfunc&gt;:0 |
| 7 | 3.3% | 38.1% | `Nokogiri::XML::Node#get` | lib/nokogiri/pure/dom.rb:668 |
| 8 | 2.8% | 3.3% | `Nokogiri::XML::Node#node_type` | lib/nokogiri/pure/dom.rb:201 |
| 9 | 2.7% | 20.1% | `Array#each` | &lt;internal:array&gt;:219 |
| 10 | 1.9% | 1.9% | `String#index` | &lt;cfunc&gt;:0 |
| 11 | 1.8% | 16.2% | `Nokogiri::XML::Node#content` | lib/nokogiri/pure/dom.rb:245 |
| 12 | 1.6% | 1.6% | `Nokogiri::XML::Node#pure` | lib/nokogiri/pure/dom.rb:165 |
| 13 | 1.6% | 2.6% | `Nokogiri::XML::NodeSet#push` | lib/nokogiri/pure/dom.rb:1363 |
| 14 | 1.4% | 2.1% | `Nokogiri::XML::NodeSet#[]` | lib/nokogiri/pure/dom.rb:1375 |
| 15 | 1.3% | 1.3% | `Regexp#match` | &lt;cfunc&gt;:0 |
| 16 | 0.6% | 0.8% | `Nokogiri::XML::Node#node_name` | lib/nokogiri/pure/dom.rb:205 |
| 17 | 0.6% | 0.6% | `Nokogiri::XML::Node#document` | lib/nokogiri/pure/dom.rb:214 |
| 18 | 0.6% | 0.6% | `Nokogiri::Pure::FlatState#children` | lib/nokogiri/pure/flat\_tree.rb:823 |
| 19 | 0.4% | 0.4% | `MatchData#[]` | &lt;cfunc&gt;:0 |
| 20 | 0.4% | 1.0% | `Nokogiri::CSS::SelectorCache.[]` | lib/nokogiri/css/selector\_cache.rb:11 |
| 21 | 0.3% | 0.3% | `Array#join` | &lt;cfunc&gt;:0 |
| 22 | 0.3% | 0.5% | `Nokogiri::Pure::FlatState#attributes` | lib/nokogiri/pure/flat\_tree.rb:832 |
| 23 | 0.3% | 0.3% | `Array#[]` | &lt;cfunc&gt;:0 |
| 24 | 0.3% | 3.7% | `Class#new` | &lt;cfunc&gt;:0 |
| 25 | 0.3% | 0.3% | `Nokogiri::XML::NodeSet#members` | lib/nokogiri/pure/dom.rb:1420 |
| 26 | 0.3% | 100.0% | `block (2 levels) in <main>` | /tmp/profile\_hot.rb:33 |
| 27 | 0.2% | 0.5% | `Nokogiri::XML::Node#namespace` | lib/nokogiri/pure/dom.rb:474 |
| 28 | 0.2% | 0.2% | `Nokogiri::Pure::FlatTree#wrapper` | lib/nokogiri/pure/flat\_tree.rb:468 |
| 29 | 0.2% | 0.2% | `Nokogiri::XML::NodeSet#wrap_subset` | lib/nokogiri/pure/dom.rb:1424 |
| 30 | 0.2% | 0.2% | `Nokogiri::XML::NodeSet#member!` | lib/nokogiri/pure/dom.rb:1436 |

### By Total Time

| Rank | Total % | Self % | Function | Location |
|------|--------|---------|----------|----------|
| 1 | 100.0% | 0.0% | `<main>` | /tmp/profile\_hot.rb:0 |
| 2 | 100.0% | 0.0% | `Hash#each` | &lt;cfunc&gt;:0 |
| 3 | 100.0% | 0.0% | `Vernier.profile` | gem:vernier-1.11.0:lib/vernier.rb:24 |
| 4 | 100.0% | 0.3% | `block (2 levels) in <main>` | /tmp/profile\_hot.rb:33 |
| 5 | 100.0% | 0.1% | `block in <main>` | /tmp/profile\_hot.rb:27 |
| 6 | 70.3% | 12.0% | `Nokogiri::XML::NodeSet#each` | lib/nokogiri/xml/node\_set.rb:233 |
| 7 | 70.3% | 3.9% | `Integer#upto` | &lt;cfunc&gt;:0 |
| 8 | 38.3% | 0.2% | `Nokogiri::XML::Node#[]` | lib/nokogiri/xml/node.rb:763 |
| 9 | 38.1% | 3.3% | `Nokogiri::XML::Node#get` | lib/nokogiri/pure/dom.rb:668 |
| 10 | 32.2% | 27.7% | `Enumerable#find` | &lt;cfunc&gt;:0 |
| 11 | 29.4% | 0.0% | `Nokogiri::XML::Searchable#css` | lib/nokogiri/xml/searchable.rb:134 |
| 12 | 28.6% | 0.0% | `Nokogiri::XML::Searchable#css_internal` | lib/nokogiri/xml/searchable.rb:241 |
| 13 | 26.3% | 0.0% | `Nokogiri::XML::Searchable#xpath_internal` | lib/nokogiri/xml/searchable.rb:261 |
| 14 | 26.2% | 0.0% | `Nokogiri::XML::Searchable#xpath_impl` | lib/nokogiri/xml/searchable.rb:276 |
| 15 | 25.8% | 0.0% | `Nokogiri::XML::XPathContext#evaluate` | lib/nokogiri/pure/xpath.rb:1901 |
| 16 | 25.8% | 0.1% | `Nokogiri::Pure::XPath.evaluate` | lib/nokogiri/pure/xpath.rb:20 |
| 17 | 22.2% | 0.1% | `Nokogiri::Pure::XPath.fast_nodes` | lib/nokogiri/pure/xpath.rb:59 |
| 18 | 20.4% | 0.1% | `Nokogiri::Pure::XPath.named` | lib/nokogiri/pure/xpath.rb:133 |
| 19 | 20.3% | 12.9% | `Nokogiri::Pure::FlatTree#named` | lib/nokogiri/pure/flat\_tree.rb:243 |
| 20 | 20.1% | 2.7% | `Array#each` | &lt;internal:array&gt;:219 |
| 21 | 16.2% | 1.8% | `Nokogiri::XML::Node#content` | lib/nokogiri/pure/dom.rb:245 |
| 22 | 11.9% | 9.2% | `Nokogiri::XML::Node#collect_text` | lib/nokogiri/pure/dom.rb:979 |
| 23 | 7.1% | 7.1% | `Nokogiri::Pure::FlatTree#local_eq?` | lib/nokogiri/pure/flat\_tree.rb:573 |
| 24 | 3.7% | 0.3% | `Class#new` | &lt;cfunc&gt;:0 |
| 25 | 3.4% | 0.1% | `Nokogiri::XML::NodeSet#initialize` | lib/nokogiri/xml/node\_set.rb:22 |
| 26 | 3.3% | 2.8% | `Nokogiri::XML::Node#node_type` | lib/nokogiri/pure/dom.rb:201 |
| 27 | 2.6% | 1.6% | `Nokogiri::XML::NodeSet#push` | lib/nokogiri/pure/dom.rb:1363 |
| 28 | 2.3% | 0.2% | `Array#map` | &lt;internal:array&gt;:237 |
| 29 | 2.3% | 0.0% | `Nokogiri::XML::Searchable#css_rules_to_xpath` | lib/nokogiri/xml/searchable.rb:245 |
| 30 | 2.2% | 0.2% | `Nokogiri::XML::Searchable#xpath_query_from_css_rule` | lib/nokogiri/xml/searchable.rb:249 |

## Threads

### /tmp/profile\_hot.rb

| Property | Value |
|----------|-------|
| TID | 991670 |
| Main Thread | yes |
| Samples | 8517 |
| Total Weight | 9079 |

## Hot Files

### lib/nokogiri/pure/dom.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 23.3% | 23.3% | `_source unavailable_` |
| 679 | 0.4% | 34.1% | `attr = pure.attributes.find { \|item\| item.name == name &&...` |
| 202 | 0.2% | 0.6% | `pure.type` |
| 982 | 0.1% | 1.1% | `case child.node_type` |
| 215 | 0.1% | 0.1% | `pure.document` |

### lib/nokogiri/pure/flat\_tree.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 21.1% | 21.1% | `_source unavailable_` |
| 248 | 0.1% | 0.1% | `while i < last` |
| 249 | 0.1% | 7.3% | `if @type[i] == ELEMENT && local_eq?(i, local, want) && hr...` |
| 253 | 0.1% | 0.1% | `i += 1` |
| 244 | 0.0% | 0.0% | `want = local.bytesize` |

### lib/nokogiri/xml/node\_set.rb

| Line | Self % | Total % | Code |
|------|--------|---------|------|
| 0 | 11.8% | 11.8% | `_source unavailable_` |
| 237 | 0.3% | 54.7% | `yield self[x]` |
| 236 | 0.0% | 70.3% | `0.upto(length - 1) do \|x\|` |
| 25 | 0.0% | 5.9% | `list.each { \|x\| self << x }` |
| 24 | 0.0% | 0.0% | `document.decorate(self)` |

