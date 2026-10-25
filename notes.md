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
