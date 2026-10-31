#!/bin/sh
# Build the optional flat-XML filler for the current machine.
# rb-sys builds against the Ruby on PATH (or $RUBY). Rebuild after a Ruby upgrade.
set -eu
cd "$(dirname "$0")"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/nokogiri-rust-flat-target}"
export RUSTFLAGS="-C link-arg=-Wl,--unresolved-symbols=ignore-all -C target-cpu=native"
cargo build --release
cp "$CARGO_TARGET_DIR/release/libnokogiri_rust_flat.so" ../../lib/nokogiri/pure/nokogiri_rust_flat.so
