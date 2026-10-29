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

The score after commit `68a706e2` was 3.638386. A kept change had to beat 3.189.

The score after commit `eb896325` was the higher of two runs: 2.983484. The other run scored 2.803185. Both runs beat 3.189.

The score after commit `7b828b66` was the higher of two runs: 2.565930. The other run scored 2.552333. Both runs beat 2.615.

The current score is the higher of the two runs after commit `a0cce8f8`: **2.248783**.

The other run scored 2.112761. Both runs beat 2.249.

The next kept change must beat `2.249 * (1 - 0.1235) = 1.971`.

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

## Current ratios

Higher of the two runs after commit `a0cce8f8`:

| Case | Baseline | After XPath | Current |
| --- | --- | --- | --- |
| parse_xml_small | 2.636 | 2.683 | 3.028 |
| parse_xml_medium | 2.731 | 2.889 | 3.593 |
| parse_xml_large | 5.656 | 6.022 | 6.108 |
| parse_html_small | 3.106 | 3.736 | 3.353 |
| parse_html_medium | 6.395 | 7.188 | 7.523 |
| parse_html_large | 5.223 | 4.560 | 8.088 |
| xpath_xml_medium | 14.303 | 1.877 | 2.065 |
| css_html_medium | 3.129 | 3.134 | 3.973 |
| traverse_xml_medium | 0.750 | 0.741 | 0.745 |
| edit_xml_medium | 7.050 | 5.307 | 0.962 |
| serialize_xml_medium | 7.581 | 8.580 | 1.004 |
| serialize_html_medium | 2.977 | 3.477 | 0.315 |

Baseline run geomeans: 4.011415, 4.056096, 4.261804. Median: 4.056096.

XPath run geomeans: 3.315608, 3.687068, 3.638386. Median: 3.638386.

Serializer run geomeans: 2.983484, 2.803185. Higher value: 2.983484.

Edit run geomeans: 2.565930, 2.552333. Higher value: 2.565930.

HTML serialize run geomeans: 2.112761, 2.248783. Higher value: 2.248783.

The HTML serialize pure times were 0.026 s and 0.026 s. The libxml times were 0.083 s and 0.095 s.

The edit case pure times were 0.078 s and 0.083 s. The libxml edit time moved between 0.084 s and 0.114 s.

Cases other than XPath, XML serialize, HTML serialize, and edit still move with machine load.

## Current hotspots

Profile tool: vernier 1.11.0, wall time, YJIT on, about 1.5 seconds.

XPath `//xmlns:item/xmlns:name` (ratio 1.88):

- The fast walk handles this query on the flat table.
- The pure entry point rewrites `xmlns:` to ` :` before evaluate. The space is the default namespace.

XML serialize (ratio 1.00):

- Default `to_xml` writes from the flat table.

HTML serialize (ratio 0.32):

- Default `to_html` copies pieces recorded on the first call.
- A tree edit drops the record. The node walker still serves other save options.

Node edit (ratio 0.93):

- Element `content=` stores the input string on a new text node.
- The old children are unlinked. The caller still receives a new text node.
- Escape and decode are skipped. Those two scans restore the input.

XML parse (ratio about 2.6 to 5.7):

- `Parser#try_flat_tree` 21 percent self
- `StringScanner#skip` 14 percent
- `String#byteindex` 11 percent
- `Parser#flat_read_attrs` 9 percent

HTML parse (ratio about 3.4 to 8.1):

- The cost is spread across `parse_loop_general`, entity split, and attribute reads.
- No single method is above 6 percent self time.

## Tried

Kept:

- Flat table for plain XML, lazy text decode, and the earlier search and serialize work. This is commit `ac87983f`. It is the baseline, not an experiment in this loop.
- Namespaced `//parent/child` on the flat table. Commit `68a706e2`. The XPath ratio fell from 14.303 to 1.877.
- Default XML serialization from the flat table. Commit `eb896325`. The serialize_xml ratio fell from about 8.6 to about 1.13. Two full runs scored 2.983484 and 2.803185.
- Element `content=` stores the input text and skips the escape and decode scans. Commit `7b828b66`. The edit ratio fell from about 5.3 to 0.932 and 0.724. Two full runs scored 2.565930 and 2.552333. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips.
- Default HTML serialization replays recorded pieces. Commit `a0cce8f8`. The serialize_html ratio fell from about 4.0 to 0.315 and 0.271. Two full runs scored 2.112761 and 2.248783. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips.

Discarded in this loop:

- HTML byte scanner for tags, end tags, and comments. The medium HTML pure time fell from about 0.67 s to 0.489 s. Small was 2.42 times libxml. Large stayed near 5 times libxml. A 1.3 times gain on the HTML parse cases does not beat 1.971. The parser change was reset.

## Open hypotheses

1. Speed the HTML general loop on attributes and text. Expected impact: medium. The cost is diffuse. HTML parse medium is the slowest remaining steady case. The higher ratio is 7.523. One noisy large-HTML run reached 8.088.
2. Cut Ruby work inside `try_flat_tree` (attribute bytes, fewer calls). Expected impact: medium for XML parse. A byte loop was already slower than `byteslice` and was reverted before this loop. The higher parse_xml_large ratio is 6.108.

## Idea categories

- Tokenizer: not tried in this loop. Flat XML already uses `StringScanner#skip`.
- Allocation: one kept change. Commit `7b828b66`. Element text no longer goes through `public_send`.
- YJIT-friendly shapes: not tried in this loop.
- Data structures: flat table is already in the baseline.
- XPath and CSS: one kept change. Commit `68a706e2`.
- Serialization: two kept changes. XML commit `eb896325`. HTML commit `a0cce8f8`. Other save options still use the node walker.
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
- `bench/autoresearch/guard.rb` passes `chdir: nil` into `Open3.capture3`. That raises `TypeError` on Ruby 3.4.7. Run `bench/autoresearch/diff.rb`, then `suite_runner.rb` with `bundle exec` from `/tmp/nokogiri-main`. Do not edit the harness to fix this.
