//! Shared records for the HTML5 tokenizer and tree builder.
//!
//! Node identity is the `Rc` pointer. That matches the Ruby tree builder,
//! which compares nodes with `equal?`.

use std::cell::RefCell;
use std::rc::{Rc, Weak};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Ns {
    Html,
    Svg,
    MathMl,
    Xlink,
    Xml,
    Xmlns,
}

impl Ns {
    pub fn from_name(name: &str) -> Self {
        match name {
            "svg" => Self::Svg,
            "mathml" => Self::MathMl,
            "xlink" => Self::Xlink,
            "xml" => Self::Xml,
            "xmlns" => Self::Xmlns,
            _ => Self::Html,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TokenKind {
    Eof,
    Character,
    Whitespace,
    Null,
    Cdata,
    Comment,
    Doctype,
    StartTag,
    EndTag,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TokState {
    Data,
    Rcdata,
    Rawtext,
    ScriptData,
    Plaintext,
    TagOpen,
    EndTagOpen,
    TagName,
    BeforeAttrName,
    AttrName,
    AfterAttrName,
    BeforeAttrValue,
    AttrDouble,
    AttrSingle,
    AttrUnquoted,
    AfterAttrValue,
    SelfClosing,
    RcdataLt,
    RcdataEndOpen,
    RcdataEndName,
    RawtextLt,
    RawtextEndOpen,
    RawtextEndName,
    ScriptLt,
    ScriptEndOpen,
    ScriptEndName,
    ScriptEscapedStart,
    ScriptEscapedStartDash,
    ScriptEscaped,
    ScriptEscapedDash,
    ScriptEscapedDashDash,
    ScriptEscapedLt,
    ScriptEscapedEndOpen,
    ScriptEscapedEndName,
    ScriptDoubleEscapedStart,
    ScriptDoubleEscaped,
    ScriptDoubleEscapedDash,
    ScriptDoubleEscapedDashDash,
    ScriptDoubleEscapedLt,
    ScriptDoubleEscapedEnd,
    BogusComment,
    MarkupDeclaration,
    CommentStart,
    CommentStartDash,
    Comment,
    CommentLt,
    CommentLtBang,
    CommentLtBangDash,
    CommentLtBangDashDash,
    CommentEndDash,
    CommentEnd,
    CommentEndBang,
    Doctype,
    BeforeDoctypeName,
    DoctypeName,
    AfterDoctypeName,
    AfterDoctypePublic,
    BeforeDoctypePublic,
    DoctypePublicDouble,
    DoctypePublicSingle,
    AfterDoctypePublicId,
    BetweenDoctypeIds,
    AfterDoctypeSystem,
    BeforeDoctypeSystem,
    DoctypeSystemDouble,
    DoctypeSystemSingle,
    AfterDoctypeSystemId,
    BogusDoctype,
    Cdata,
    CdataBracket,
    CdataEnd,
    CharacterReference,
    NamedReference,
    AmbiguousAmpersand,
    NumericReference,
    HexStart,
    DecStart,
    HexRef,
    DecRef,
    NumericEnd,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub kind: TokenKind,
    pub name: String,
    pub data: String,
    pub public_id: String,
    pub system_id: String,
    pub has_public_id: bool,
    pub has_system_id: bool,
    pub force_quirks: bool,
    pub attrs: Vec<(String, String)>,
    pub self_closing: bool,
    pub line: i32,
    pub column: i32,
    pub byte_offset: i32,
    pub original: String,
}

impl Token {
    pub fn blank(kind: TokenKind) -> Self {
        Self {
            kind,
            name: String::new(),
            data: String::new(),
            public_id: String::new(),
            system_id: String::new(),
            has_public_id: false,
            has_system_id: false,
            force_quirks: false,
            attrs: Vec::new(),
            self_closing: false,
            line: 0,
            column: 0,
            byte_offset: 0,
            original: String::new(),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum NodeKind {
    Document,
    Element,
    Text,
    Cdata,
    Comment,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TextKind {
    Whitespace,
    Text,
    Cdata,
}

#[derive(Debug)]
pub struct NodeInner {
    pub kind: NodeKind,
    pub name: String,
    pub namespace: Ns,
    pub attrs: Vec<(String, String, Option<Ns>)>,
    pub children: Vec<NodeRef>,
    pub parent: Weak<RefCell<NodeInner>>,
    pub quirks_mode: i32,
    pub doctype_name: String,
    pub public_id: String,
    pub system_id: String,
    pub has_doctype: bool,
    pub line: i32,
    pub content: String,
}

#[derive(Clone, Debug)]
pub struct NodeRef(pub Rc<RefCell<NodeInner>>);

impl NodeRef {
    pub fn new(kind: NodeKind) -> Self {
        Self(Rc::new(RefCell::new(NodeInner {
            kind,
            name: String::new(),
            namespace: Ns::Html,
            attrs: Vec::new(),
            children: Vec::new(),
            parent: Weak::new(),
            quirks_mode: 0,
            doctype_name: String::new(),
            public_id: String::new(),
            system_id: String::new(),
            has_doctype: false,
            line: 0,
            content: String::new(),
        })))
    }

    pub fn same(&self, other: &Self) -> bool {
        Rc::ptr_eq(&self.0, &other.0)
    }
}

impl PartialEq for NodeRef {
    fn eq(&self, other: &Self) -> bool {
        self.same(other)
    }
}

#[derive(Clone, Debug)]
pub enum FormEntry {
    Scope,
    Node(NodeRef),
}

impl FormEntry {
    pub fn is_scope(&self) -> bool {
        matches!(self, Self::Scope)
    }

    pub fn node(&self) -> Option<&NodeRef> {
        match self {
            Self::Node(node) => Some(node),
            Self::Scope => None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ParseError {
    pub code: String,
    pub message: String,
    pub line: i32,
    pub column: i32,
    pub byte_offset: i32,
}

#[derive(Debug)]
pub struct ErrorLog {
    max_errors: i64,
    pub errors: Vec<ParseError>,
}

impl ErrorLog {
    pub fn new(max_errors: i64) -> Self {
        Self { max_errors, errors: Vec::new() }
    }

    /// A limit of 0 records nothing. A negative limit records every error.
    pub fn add(&mut self, code: &str, message: String, line: i32, column: i32, byte_offset: i32) {
        if self.max_errors >= 0 && self.max_errors <= self.errors.len() as i64 {
            return;
        }
        self.errors.push(ParseError {
            code: code.to_string(),
            message,
            line,
            column,
            byte_offset,
        });
    }
}

#[derive(Clone, Debug)]
pub struct Options {
    pub max_attributes: i64,
    pub max_errors: i64,
    pub max_tree_depth: i64,
    pub noscript_as_text: bool,
    pub fragment_context: Option<String>,
    pub fragment_namespace: Ns,
    pub fragment_encoding: Option<String>,
    pub quirks_mode: i32,
    pub form_ancestor: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            max_attributes: 400,
            max_errors: 0,
            max_tree_depth: 400,
            noscript_as_text: false,
            fragment_context: None,
            fragment_namespace: Ns::Html,
            fragment_encoding: None,
            quirks_mode: 0,
            form_ancestor: false,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Status {
    Ok,
    TooManyAttributes,
    TreeTooDeep,
}

#[derive(Debug)]
pub struct Output {
    pub document: NodeRef,
    pub root: Option<NodeRef>,
    pub errors: Vec<ParseError>,
    pub quirks_mode: i32,
    pub status: Status,
}

/// ASCII `A-Z` to `a-z` only. This is `String#tr("A-Z", "a-z")`, not Unicode casefold.
pub fn ascii_lower(value: &str) -> String {
    value.chars().map(|ch| {
        if ch.is_ascii_uppercase() { (ch as u8 + 32) as char } else { ch }
    }).collect()
}

pub fn eq_lower(value: &str, lower: &str) -> bool {
    if value.len() != lower.len() {
        return false;
    }
    value.bytes().zip(lower.bytes()).all(|(left, right)| {
        let folded = if left.is_ascii_uppercase() { left + 32 } else { left };
        folded == right
    })
}
