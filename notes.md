# Performance notes

Tag: oct25. Branch: `perf/oct25`. Base commit: `76595a96`.

The branch starts from `pure-ruby`, not git `main`. Git `main` is the C extension. This loop measures the pure Ruby backend.

## Noise floor

Harness: `benchmark/common_uses.rb` child mode, Ruby 3.4.7, warmup 1s, measure 2s. `parse_html5` skips because `uses_gumbo?` is false. The score uses the other 12 tasks. Score is the geometric mean of (new iterations per second / baseline iterations per second).

Five runs on the baseline commit. Spread is (max - min) / median.

| Benchmark | Median i/s | Spread |
| --- | ---: | ---: |
| parse_html | 6.526 | 25.7% |
| parse_xml | 54.843 | 22.9% |
| css_scrape | 40.955 | 36.0% |
| at_css | 14339 | 50.7% |
| xpath_links | 194.829 | 36.5% |
| serialize_html | 117.778 | 37.7% |
| serialize_xml | 840.260 | 27.5% |
| parse_fragment | 1175 | 31.2% |
| build_xml | 1116 | 30.1% |
| edit_document | 21.520 | 43.9% |
| atom_titles | 62.757 | 35.1% |
| sax_html | 24.165 | 11.0% |

The five full-suite scores against this median were 0.921, 0.913, 1.022, 1.020, and 0.983. The score spread is 11.1%.

The suggested 3% regression guard is below the noise on every benchmark. A slowdown counts only when the median of 3 runs is worse than that benchmark's spread. A keep requires a 3-run median score of at least 1.060, which is outside the baseline score range.

Host load was falling during the five runs (11 to 4). Later experiments must use the same 3-run median.

## Baseline

`76595a96` is the first keep. Score 1.000. It already contains the query, parser, and serializer speedups made before this loop.

## Reference reset

The first five runs started while the host load was near 11. Untouched benchmarks were slower than later quiet runs. The reference iterations per second are now the interleaved medians of `bba2b49a`. Later scores in this file are cumulative against `76595a96`.

## Experiments

### 3. Discard. Scan SAX attribute values in one pass

Commit `643981a8`, then reset. Median of 3 paired runs versus `03a3c7ef`: score 1.017. `sax_html` went from 30.4 i/s to 39.7 i/s. The other benchmarks did not move outside noise, so the geomean did not clear the noise floor. The branch does not contain this commit.

### 2. Keep. Link fresh parser nodes directly

Commit `03a3c7ef`. Median of 6 paired runs versus `bba2b49a`: score 1.048, cumulative 1.128. Worst median change is serialize_html at -13.0%. That benchmark does not use the parser append path, and the move is inside its 37% spread. `parse_html` median went from 7.76 i/s to 9.59 i/s. `parse_fragment` went from 1414 i/s to 1776 i/s. `parse_xml` went from 76.5 i/s to 86.2 i/s. The full suite finished in 14.1 seconds, with 0 failures and 0 errors.

### 1. Keep. Compile simple predicates once

Commit `bba2b49a`. Fair score 1.077 against a paired run of `76595a96`. Worst median change is atom_titles at -2.4%, inside the noise. `xpath_links` went from 275 i/s to 456 i/s. `css_scrape` went from 59.9 i/s to 63.0 i/s. The class and attribute patterns are compiled when the step is built. The descendant walk checks an unprefixed name without `name_match?`.

## Files on pure-ruby

These notes and `benchmark/common_uses.rb` lived on branch `xmloxide`. The score rows are in `benchmark/oct25-results.tsv`. The file `results.tsv` at the repo root is the later autoresearch log. Do not replace it with the oct25 rows.

The harness compares libxml2, this pure-Ruby tree, and xmloxide. It adds the xmloxide column only when `lib/nokogiri/nokogiri.so` is in this tree.

## Recorded three-backend run

Date: 2026-10-25. Ruby 3.4.7. Warmup 1 second. Measure 2 seconds. Command: `ruby benchmark/common_uses.rb`.

Trees: libxml2 `2d0f04bd` with Gumbo, pure-ruby `b37431ad`, xmloxide `ba9657a1` plus uncommitted speed edits. `parse_html5` ran only on libxml2.

xmloxide versus libxml2 on that run:

- Faster or level: parse_html 2.14x, parse_xml within error, css_scrape 1.51x, at_css 1.78x, xpath_links 1.27x, serialize_html 2.19x, parse_fragment 1.14x, edit_document 1.39x.
- Slower: serialize_xml 1.15x, build_xml 1.67x (spread 24.3 percent), atom_titles 1.48x, sax_html 1.29x.

That run did not save iterations per second in git. The ratios above are the recorded comparison.

## Ruby edits from xmloxide commit d57d38b1

Already on this branch:

- HTML charset detection does not use the SAX push parser. `EncodingReader.detect_html_charset` landed in `ac87983f`.
- Element `content=` stores the input text and skips the escape scan. That override is `lib/nokogiri/pure/element_content.rb` in `7b828b66`.

Not copied:

- `Node#add_child_node_and_reparent_attrs` returns immediately when the attribute list is empty. The behavior matches the current loop. Copy it after the in-flight autoresearch baseline.
- `CSS::XPathVisitor#css_class` emits `nokogiri-builtin:css-class` unless the runtime is JRuby. This branch emits that builtin only when `uses_libxml?` is true. The pure fast path matches the `contains(...)` form. Do not switch this branch to the builtin.
- `Document#namespace_inheritance=` writes the native flag. That call belongs to the extension. This branch does not use it.
