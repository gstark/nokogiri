#!/bin/sh
# Build the optional flat-XML filler for the current machine.
# rb-sys builds against the Ruby on PATH (or $RUBY). Rebuild after a Ruby upgrade.
#
# TOKENIZER picks the HTML5 tokenizer:
#   html5gum (default)  the html5gum crate
#   own                 the crate's own tokenizer in src/html5/lex.rs
# Nokogiri::Pure::RustHtml5::TOKENIZER names the one that Ruby loaded.
set -eu
cd "$(dirname "$0")"
TOKENIZER="${TOKENIZER:-html5gum}"
case "$TOKENIZER" in
  html5gum) features="--features ruby,html5gum" ;;
  own) features="--features ruby" ;;
  *) echo "TOKENIZER must be html5gum or own, not $TOKENIZER" >&2; exit 1 ;;
esac
# A target directory for each tokenizer, so a switch does not rebuild all crates.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/nokogiri-rust-flat-target-$TOKENIZER}"
export RUSTFLAGS="-C link-arg=-Wl,--unresolved-symbols=ignore-all -C target-cpu=native"
# shellcheck disable=SC2086
cargo build --release --no-default-features $features
cp "$CARGO_TARGET_DIR/release/libnokogiri_rust_flat.so" ../../lib/nokogiri/pure/nokogiri_rust_flat.so
