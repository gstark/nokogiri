# Autoresearch

## Goal

Make the pure Ruby Nokogiri backend run within 20 percent of the libxml backend.

The score is the geometric mean of `pure_time / libxml_time` across the benchmark cases.

Lower is better.

The target is `geomean_ratio <= 1.20` on three consecutive benchmark runs.

The target is met. Commit `5c70ede8` scored 1.178320, 1.108242, and 1.177141.

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

The score after commit `a0cce8f8` was the higher of two runs: 2.248783. The other run scored 2.112761. Both runs beat 2.249.

The current score is the higher of the three runs after commit `5c70ede8`: **1.178320**.

The other runs scored 1.108242 and 1.177141. All three runs beat 1.181. All three runs are at or under 1.20.

The next kept change must beat `1.178320 * (1 - 0.1235) = 1.033`. The target is already met. The loop stops here.

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

Higher of the three runs after commit `5c70ede8`:

| Case | Baseline | After HTML flat | Current |
| --- | --- | --- | --- |
| parse_xml_small | 2.636 | 2.797 | 2.553 |
| parse_xml_medium | 2.731 | 3.011 | 1.407 |
| parse_xml_large | 5.656 | 6.125 | 1.851 |
| parse_html_small | 3.106 | 1.168 | 1.303 |
| parse_html_medium | 6.395 | 1.509 | 1.746 |
| parse_html_large | 5.223 | 1.060 | 1.286 |
| xpath_xml_medium | 14.303 | 1.928 | 2.052 |
| css_html_medium | 3.129 | 2.189 | 1.934 |
| traverse_xml_medium | 0.750 | 0.560 | 0.769 |
| edit_xml_medium | 7.050 | 0.829 | 0.778 |
| serialize_xml_medium | 7.581 | 1.323 | 1.378 |
| serialize_html_medium | 2.977 | 0.319 | 0.293 |

Baseline run geomeans: 4.011415, 4.056096, 4.261804. Median: 4.056096.

XPath run geomeans: 3.315608, 3.687068, 3.638386. Median: 3.638386.

Serializer run geomeans: 2.983484, 2.803185. Higher value: 2.983484.

Edit run geomeans: 2.565930, 2.552333. Higher value: 2.565930.

HTML serialize run geomeans: 2.112761, 2.248783. Higher value: 2.248783.

HTML parse run geomeans: 1.279334, 1.347284. Higher value: 1.347284.

Repeated-sibling run geomeans: 1.178320, 1.108242, 1.177141. Higher value: 1.178320.

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

XML parse (higher ratios 2.553, 1.407, and 1.851):

- Commit `5c70ede8` learns the first child element and matches later copies with one pattern.
- A document that does not repeat falls back to the flat scan.
- The large XML ratio fell from 6.125 to 1.851. The medium XML ratio fell from 3.011 to 1.407.

HTML parse (ratio about 1.06 to 1.51):

- Supported HTML is stored as indexes on the flat table. Commit `b3c36df7`.
- The parse benchmark reads only the root name. A Ruby node is built when a reader asks.
- `css_html_medium` fell to 2.189 because `flat.named` walks those indexes.
- Medium HTML libxml time is noisy. Do not chase that case alone.

## Tried

Kept:

- Flat table for plain XML, lazy text decode, and the earlier search and serialize work. This is commit `ac87983f`. It is the baseline, not an experiment in this loop.
- Namespaced `//parent/child` on the flat table. Commit `68a706e2`. The XPath ratio fell from 14.303 to 1.877.
- Default XML serialization from the flat table. Commit `eb896325`. The serialize_xml ratio fell from about 8.6 to about 1.13. Two full runs scored 2.983484 and 2.803185.
- Element `content=` stores the input text and skips the escape and decode scans. Commit `7b828b66`. The edit ratio fell from about 5.3 to 0.932 and 0.724. Two full runs scored 2.565930 and 2.552333. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips.
- Default HTML serialization replays recorded pieces. Commit `a0cce8f8`. The serialize_html ratio fell from about 4.0 to 0.315 and 0.271. Two full runs scored 2.112761 and 2.248783. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips.
- HTML parse stores tags as indexes on the flat table. Commit `b3c36df7`. The higher HTML ratios are 1.168, 1.509, and 1.060. The CSS ratio fell to 2.189. Two full runs scored 1.279334 and 1.347284. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips.
- Repeated XML siblings share one learned shape. Commit `5c70ede8`. The higher XML parse ratios are 2.553, 1.407, and 1.851. Three full runs scored 1.178320, 1.108242, and 1.177141. All three are at or under 1.20. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips.

Discarded in this loop:

- HTML byte scanner for tags, end tags, and comments. The medium HTML pure time fell from about 0.67 s to 0.489 s. Small was 2.42 times libxml. Large stayed near 5 times libxml. A 1.3 times gain on the HTML parse cases does not beat 1.971. The parser change was reset.
- Packed XML records and attribute offsets, then a tighter tag loop. Large-file objects fell from about 1.3 million to about 0.2 million. In one process the large parse was about 1.4 times faster and the medium parse about 1.3 times faster. The small parse was slower. A YJIT slice of the same loop was several times slower. The change does not beat 1.181. The parser change was reset.

## Open hypotheses

The target is met. Do not start another keep for score alone.

The furthest ratios are `parse_xml_small` at 2.553, `xpath_xml_medium` at 2.052, and `css_html_medium` at 1.934. Small XML does not repeat one child shape, so the new path leaves it on the flat scan.

The tighter tag loop and packed records did not beat 1.181. Do not repeat that edit.

## Idea categories

- Tokenizer: not tried in this loop. Flat XML already uses `StringScanner#skip`.
- Allocation: two kept changes. Commit `7b828b66` skips a scan for element text. Commit `b3c36df7` stores HTML tags as indexes.
- YJIT-friendly shapes: not tried in this loop.
- Data structures: the XML flat table is in the baseline. HTML records were added in commit `b3c36df7`.
- XPath and CSS: one kept change. Commit `68a706e2`.
- Serialization: two kept changes. XML commit `eb896325`. HTML commit `a0cce8f8`. Other save options still use the node walker.
- Algorithmic: one kept change. Commit `5c70ede8` matches repeated siblings from the first child.

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
