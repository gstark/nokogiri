#![no_main]

use libfuzzer_sys::fuzz_target;
use nokogiri_rust_flat::fill::parse;

fuzz_target!(|data: &[u8]| {
    let (origin, bytes) = match data.split_first() {
        Some((head, rest)) => ((*head as usize) % (rest.len() + 1), rest),
        None => (0, data),
    };
    let _ = parse(bytes, origin);
});
