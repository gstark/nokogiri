#![no_main]

use libfuzzer_sys::fuzz_target;
use nokogiri_rust_flat::html5::model::{NodeRef, Ns};
use nokogiri_rust_flat::html5::{parse, Options};

fuzz_target!(|data: &[u8]| {
    let mode = data.first().copied().unwrap_or(0);
    let body = if data.len() > 1 { &data[1..] } else { b"" };
    let text = String::from_utf8_lossy(body);
    let mut options = Options::default();
    match mode % 5 {
        1 => options.fragment_context = Some("div".to_string()),
        2 => {
            options.fragment_context = Some("svg".to_string());
            options.fragment_namespace = Ns::Svg;
        }
        3 => {
            options.fragment_context = Some("math".to_string());
            options.fragment_namespace = Ns::MathMl;
            options.max_errors = -1;
        }
        4 => options.fragment_context = Some("td".to_string()),
        _ => {}
    }
    let output = parse(text.as_ref(), &options);
    touch(&output.document, 0);
});

fn touch(node: &NodeRef, depth: usize) {
    if depth > 32 {
        return;
    }
    let children = node.0.borrow().children.clone();
    for child in children {
        touch(&child, depth + 1);
    }
}
