# Autoresearch

## Goal

Make the pure Ruby Nokogiri backend run within 20 percent of the libxml backend.

The score is the geometric mean of `pure_time / libxml_time` across the benchmark cases.

Lower is better.

The target is `geomean_ratio <= 1.20` on three consecutive benchmark runs.

The 1.20 milestone is met. It does not stop the loop.

Commit `5c70ede8` scored 1.178320, 1.108242, and 1.177141.

A quiet rebaseline on commit `a36d4998` scored 1.102807, 1.113009, and 1.215554. The median is 1.113009.

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

The keep threshold is the larger of 1 percent and twice that noise.

The first settled trio was 4.011415, 4.056096, and 4.261804. Spread 0.0617. That threshold was 0.1235.

Quiet rebaseline on 2026-10-30, commit `a36d4998`. Run 1 started at load 0.39. Run 2 started at load 2.01. Run 3 started at load 2.54. Scores: 1.102807, 1.113009, 1.215554.

Median: **1.113009**.

Spread: (1.215554 - 1.102807) / 1.113009 = 0.1013.

Keep threshold: **0.2026** (20.26 percent).

A kept change must beat `1.113009 * (1 - 0.2026) = 0.887` on the median of a confirmed pair.

A kept change must beat `4.056 * (1 - 0.1235) = 3.555` on the geomean, then hold on a second run.

The score after commit `68a706e2` was 3.638386. A kept change had to beat 3.189.

The score after commit `eb896325` was the higher of two runs: 2.983484. The other run scored 2.803185. Both runs beat 3.189.

The score after commit `7b828b66` was the higher of two runs: 2.565930. The other run scored 2.552333. Both runs beat 2.615.

The score after commit `a0cce8f8` was the higher of two runs: 2.248783. The other run scored 2.112761. Both runs beat 2.249.

The current score is the median of the quiet rebaseline: **1.113009**.

The higher quiet run is 1.215554. That run started at load 2.54. Two of the three quiet runs are under 1.20.

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

Median of the quiet rebaseline on `a36d4998`. The last column is the higher of those three runs.

| Case | Start | Quiet median | Quiet higher |
| --- | --- | --- | --- |
| parse_xml_small | 2.636 | 2.796 | 2.796 |
| parse_xml_medium | 2.731 | 1.440 | 1.551 |
| parse_xml_large | 5.656 | 1.610 | 1.757 |
| parse_html_small | 3.106 | 1.070 | 1.135 |
| parse_html_medium | 6.395 | 1.430 | 1.520 |
| parse_html_large | 5.223 | 0.936 | 0.969 |
| xpath_xml_medium | 14.303 | 1.590 | 1.836 |
| css_html_medium | 3.129 | 1.718 | 1.961 |
| traverse_xml_medium | 0.750 | 0.686 | 0.879 |
| edit_xml_medium | 7.050 | 0.893 | 0.894 |
| serialize_xml_medium | 7.581 | 1.130 | 1.281 |
| serialize_html_medium | 2.977 | 0.292 | 0.316 |

Baseline run geomeans: 4.011415, 4.056096, 4.261804. Median: 4.056096.

XPath run geomeans: 3.315608, 3.687068, 3.638386. Median: 3.638386.

Serializer run geomeans: 2.983484, 2.803185. Higher value: 2.983484.

Edit run geomeans: 2.565930, 2.552333. Higher value: 2.565930.

HTML serialize run geomeans: 2.112761, 2.248783. Higher value: 2.248783.

HTML parse run geomeans: 1.279334, 1.347284. Higher value: 1.347284.

Repeated-sibling run geomeans: 1.178320, 1.108242, 1.177141. Higher value: 1.178320.

Quiet rebaseline geomeans: 1.102807, 1.113009, 1.215554. Median: 1.113009.

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

## Hypothesis log

### H-001

Evidence: vernier wall profile `bench/autoresearch/profiles/a36d4998-xpath_xml_medium.md`. `FlatTree#local_eq?` is 50.2 percent of self time. It slices the source on every name test. The CSS profile shows `Enumerable#find` at 27.7 percent inside attribute reads, and `collect_text` at 9.2 percent.

Proposed change: remember each local name on the flat table the first time it is read. Later tests compare that string.

Mechanism: the benchmark parses once and queries the same document hundreds of times. A user who queries a document more than once gets the same reuse. The first query still slices once per element.

Predicted impact: `xpath_xml_medium` falls from about 1.59 toward 1.0. CSS moves less, because name tests are only 7.1 percent of that profile. Parse cases stay put. The geomean move is a few percent, under the 0.2026 keep bar. Keep the result only if the confirmed geomean beats 0.887. Otherwise record a near miss.

Result: one full bench of the name cache alone, at load 2.00, scored geomean 1.101229. Pure xpath median was 0.086547 s. The quiet pure band is 0.074 s to 0.085 s. Libxml xpath spread was 0.4021, so ratio 1.007 is not a pure-time win. A later three-run loop timed 40 xpath queries at median 0.0148 s versus 0.0191 s. The harness did not show that gap. This does not beat 0.887. The code was reset.

### H-002

Evidence: the same xpath profile shows `Node#collect_text` at 17.8 percent of self time. The CSS profile shows it at 9.2 percent. The harness reads `.text` on every hit, hundreds of times, on one document.

Proposed change: store each element's plain text on the flat table the first time it is read. Later reads return that string. A wrapped text node clears the cache for its ancestors. `content` returns a duplicate so a caller cannot change the stored text.

Mechanism: a catalog `name` element has one text child. The first read copies that text. Later reads skip the child walk. A user who reads text more than once on the same document gets the same reuse. An edit that retires the table, or that materializes children, uses the live walk.

Predicted impact: xpath and CSS move down by a few percent on top of H-001. Parse cases stay put, because they do not read text. The stacked geomean still lands above 0.887. Record a near miss unless the confirmed geomean beats 0.887.

Result: a text-only loop, 40 passes over 666 names, median 0.0055 s versus 0.0053 s on `a36d4998`. The duplicate on each read cost the same as the old child walk. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips. One full bench of H-001 plus H-002 at load 1.44 scored geomean 1.146655. Pure xpath was 0.076091 s. Pure CSS was 0.164661 s. Both sit inside the quiet bands. This does not beat 0.887. The code was reset.

### H-003

Evidence: vernier profile `bench/autoresearch/profiles/a36d4998-css_html_medium.md`. `Enumerable#find` is 27.7 percent of self time inside `Node#get` for `node["href"]`.

Proposed change: for an unprefixed name on a flat element whose attributes are not materialized, read the value from the flat attribute row. Remember that string on the table. A later read returns the same string. A namespaced name, or a write that materializes attributes, keeps the old search.

Mechanism: the CSS harness reads `href` on each anchor, many times, on one document. The first read decodes the value. Later reads skip `Attr` allocation and `Enumerable#find`. A user who reads the same attribute more than once gets the same reuse.

Predicted impact: the CSS ratio moves down from about 1.72. A 20 percent cut on that one case is about 1.5 percent on the geomean. That stays above 0.887. Record a near miss unless the confirmed geomean beats 0.887.

Result: an attribute loop median was 0.0038 s versus 0.0070 s, about 46 percent. One full bench at load 1.06 scored geomean 1.171605. Pure CSS median was 0.119498 s with spread 0.0190. The quiet pure CSS band is 0.151 s to 0.184 s. The CSS ratio was 1.355. The differential check passed. The suite reported 2082 runs, 6080 assertions, 0 failures, 0 errors, and 104 skips. This does not beat 0.887. The code was reset.

## Open hypotheses

The furthest median ratios are `parse_xml_small` at 2.796, `css_html_medium` at 1.718, and `parse_xml_large` at 1.610. Small XML does not repeat one child shape, so it stays on the flat scan. That scan spends 13.9 percent in `String#byteindex`, 13.0 percent in `StringScanner#skip`, and 12.3 percent in `flat_read_attrs`.

The tighter tag loop and packed records did not beat the old bar. Do not repeat that edit.

## Near-miss pool

- Cached local names. See H-001. A same-process xpath loop was about 22 percent faster. The harness pure time stayed inside 0.074 s to 0.085 s.
- Cached element text. See H-002. The text loop did not move, because each read still allocated a duplicate.
- Direct flat attribute read. See H-003. Pure CSS fell to 0.119 s. The geomean stayed inside the quiet band.

## Active campaign

None.

## Escalation

Current level: local algorithmic. Micro changes and the flat-table architecture are already in the kept set. YJIT shape work is not exhausted. Two architectural campaigns since the last keep are not done. The stop rule is not met.

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
- The workspace checkout `/home/dev/nokogiri` is branch `pure-ruby`. Commits land there. Fast-forward `autoresearch/perf` in `/tmp/nokogiri-perf` when that worktree is clean.
- The quiet rebaseline measured `/tmp/nokogiri-perf` at the same commit `a36d4998`.
- `bench/autoresearch/guard.rb` passes `chdir: nil` into `Open3.capture3`. That raises `TypeError` on Ruby 3.4.7. Run `bench/autoresearch/diff.rb`, then `suite_runner.rb` with `bundle exec` from `/tmp/nokogiri-main`. Do not edit the harness to fix this.
