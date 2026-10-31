//! One-call HTML5 parser. The native call can link the finished nodes.

pub mod model;
mod quirks;
mod tokenizer;
mod tree;

pub use model::{Options, Status};
pub use tree::parse;

#[cfg(test)]
mod tests {
    use super::*;

    fn text_of(node: &model::NodeRef, out: &mut String) {
        let inner = node.0.borrow();
        if inner.kind == model::NodeKind::Text {
            out.push_str(&inner.content);
        }
        for child in &inner.children {
            text_of(child, out);
        }
    }

    #[test]
    fn longest_named_reference_decodes() {
        let output = parse("&CounterClockwiseContourIntegral;&amp;", &Options::default());
        let mut text = String::new();
        text_of(&output.document, &mut text);
        assert_eq!(text, "\u{2233}&");
    }
}
