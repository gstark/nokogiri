# Autoresearch

## Goal

Make the pure Ruby Nokogiri backend run within 20 percent of the libxml backend.

The score is the geometric mean of `pure_time / libxml_time` across the benchmark cases.

Lower is better.

The target is `geomean_ratio <= 1.20` on three consecutive benchmark runs.

## Commands

- Ruby: `/home/dev/.local/share/mise/installs/ruby/3.4.7/bin/ruby`
- Pure tree: `/tmp/nokogiri-perf`, branch `autoresearch/perf`
- Libxml tree: `/tmp/nokogiri-main`, commit `2d0f04bd`
- Nokogiri version string: `1.20.0.dev`
- libxml2: 2.9.14
- libxslt: 1.1.35

Benchmark:

```
ruby --yjit bench/autoresearch/bench.rb
```

Guard:

```
ruby --yjit bench/autoresearch/guard.rb
```

The guard runs the differential check, then the pure test suite.

The suite skips HTML5 tests. `uses_gumbo?` is false on the pure backend.

Profile:

```
ruby --yjit bench/autoresearch/profile.rb xpath
```

Modes: `parse_xml`, `parse_html`, `xpath`, `css`, `traverse`, `edit`, `to_xml`, `to_html`.

## Keep threshold

Noise is `(max - min) / median` of three consecutive geomean runs.

The keep threshold is the larger of 2 percent and twice that noise.

Settled runs: 4.011415, 4.056096, 4.261804.

Median baseline: **4.056096**.

Spread: 0.0617.

Keep threshold: **0.1235** (12.35 percent).

A kept change must beat `4.056 * (1 - 0.1235) = 3.555` on the geomean, then hold on a second run.

One earlier run scored 4.490180 before these three. That run is not part of the threshold.

## Metric rules

Each case runs in a fresh process. Pure runs, then libxml runs.

Each process warms up, collects the heap once, then takes the median of 7 samples.

YJIT is required on both sides.

Do not change the corpus, the worker timing, the differential check, or the test suite.

## Baseline ratios

Median of the three settled runs:

| Case | Ratio |
| --- | --- |
| parse_xml_small | 2.636 |
| parse_xml_medium | 2.731 |
| parse_xml_large | 5.656 |
| parse_html_small | 3.106 |
| parse_html_medium | 6.395 |
| parse_html_large | 5.223 |
| xpath_xml_medium | 14.303 |
| css_html_medium | 3.129 |
| traverse_xml_medium | 0.750 |
| edit_xml_medium | 7.050 |
| serialize_xml_medium | 7.581 |
| serialize_html_medium | 2.977 |
| geomean | 4.056 |

Traverse is already inside the target.

## Current hotspots

Profile tool: vernier 1.11.0, wall time, YJIT on, about 1.5 seconds.

XPath `//xmlns:item/xmlns:name` (ratio 14.3):

- `XPath::Engine#stamp_index` 24 percent self
- `XPath::Engine#name_match?` 13 percent self
- `XPath::Engine#gather_descendant_children` 12 percent self
- `instance_variable_get` 9 percent
- `object_id` 8 percent

The namespaced child step misses the fast walk. The full evaluator runs.

XML serialize (ratio 7.6):

- `String#gsub` 42 percent self
- `Serializer#write_element` 13 percent self

Node edit (ratio 7.1):

- `String#gsub` 27 percent self
- `State.attach` 14 percent self
- `Kernel#public_send` 9 percent
- `XML::Text.new` inside `native_content=`

XML parse (ratio about 2.6 to 5.7):

- `Parser#try_flat_tree` 21 percent self
- `StringScanner#skip` 14 percent
- `String#byteindex` 11 percent
- `Parser#flat_read_attrs` 9 percent

HTML parse (ratio about 3.1 to 6.4):

- The cost is spread across `parse_loop_general`, entity split, and attribute reads.
- No single method is above 6 percent self time.

## Tried

Kept:

- Flat table for plain XML, lazy text decode, and the earlier search and serialize work. This is commit `ac87983f`. It is the baseline, not an experiment in this loop.

Discarded in this loop: none yet.

## Open hypotheses

1. Walk `//prefix:parent/prefix:child` on the flat table. Expected impact: high. The XPath case is 14 times libxml time, and the profile is the full evaluator.
2. Replace serializer `gsub` with an escape table that writes into one buffer. Expected impact: high for `serialize_xml`.
3. Set element text by replacing the child string. Do not allocate a new text node through `public_send`. Expected impact: medium for edit.
4. Speed the HTML general loop on attributes and text. Expected impact: medium. The cost is diffuse.
5. Cut Ruby work inside `try_flat_tree` (attribute bytes, fewer calls). Expected impact: medium for XML parse. A byte loop was already slower than `byteslice` and was reverted before this loop.

## Idea categories

- Tokenizer: not tried in this loop. Flat XML already uses `StringScanner#skip`.
- Allocation: not tried in this loop.
- YJIT-friendly shapes: not tried in this loop.
- Data structures: flat table is already in the baseline.
- XPath and CSS: next experiment.
- Serialization: open.
- Algorithmic: open. XPath document-order stamping looks quadratic in the profile.

## Assumptions

- The reference build is the libxml checkout at `/tmp/nokogiri-main`. It is not a released gem number. The version string is `1.20.0.dev`.
- HTML named entities such as `&raquo;` stay different. The differential check removes non-ASCII characters from HTML text, and it compares URLs exactly.
- XML element order, namespaces, attributes, and direct text must match.
- `small_xml.xml` is `test/files/atom.xml`. Its `to_xml` bytes must match.
- `medium_html.html` is `test/files/tlm.html`.
- Medium and large XML are synthetic catalogs in the `urn:bench` namespace. They use only predefined entities and character references, so the flat parser accepts them.
- Large HTML is synthetic. It includes an unclosed `p`, comments, and predefined entities.
- A query result cache that survives across benchmark iterations is not allowed. Node caches inside one parsed document are normal user behavior.
- The workspace checkout `/home/dev/nokogiri` is a different branch. Do not edit it.
- Do not commit to any branch except `autoresearch/perf` in `/tmp/nokogiri-perf`.
