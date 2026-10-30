//! One-call HTML5 parser. The native call can link the finished nodes.

mod entities;
mod lex;
pub mod model;
mod quirks;
mod tree;

pub use model::{Options, Status};
pub use tree::parse;
