//! HTML5 tokenizer on html5gum. It keeps the token stream of the Gumbo
//! tokenizer: one character token per code point, Gumbo line and column
//! numbers, and Gumbo error messages.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::convert::Infallible;
use std::rc::Rc;

use html5gum::{Emitter, Error, Reader, State};

use crate::html5::model::{ErrorLog, TokState, Token, TokenKind};

/// Skip a leading UTF-8 BOM, scrub invalid UTF-8, then map `\r\n?` to `\n`.
fn preprocess(input: &str) -> String {
    let raw = input.as_bytes();
    let raw = raw.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(raw);
    let text = String::from_utf8_lossy(raw);
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\r' {
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
            out.push('\n');
        } else {
            out.push(ch);
        }
    }
    out
}

/// html5gum reads from a borrowed slice. This reader owns the text, so the
/// tree builder does not need a lifetime.
struct TextReader {
    text: Rc<str>,
    at: usize,
}

impl Reader for TextReader {
    type Error = Infallible;

    fn read_byte(&mut self) -> Result<Option<u8>, Infallible> {
        let byte = self.text.as_bytes().get(self.at).copied();
        if byte.is_some() {
            self.at += 1;
        }
        Ok(byte)
    }

    fn try_read_string(&mut self, s: &[u8], case_sensitive: bool) -> Result<bool, Infallible> {
        let Some(next) = self.text.as_bytes().get(self.at..self.at + s.len()) else {
            return Ok(false);
        };
        if next == s || (!case_sensitive && next.eq_ignore_ascii_case(s)) {
            self.at += s.len();
            return Ok(true);
        }
        Ok(false)
    }

    fn read_until<'b>(&'b mut self, needle: &[u8], _: &'b mut [u8; 4]) -> Result<Option<&'b [u8]>, Infallible> {
        let rest = &self.text.as_bytes()[self.at..];
        if rest.is_empty() {
            return Ok(None);
        }
        let len = match rest.iter().position(|byte| needle.contains(byte)) {
            Some(0) => 1,
            Some(index) => index,
            None => rest.len(),
        };
        self.at += len;
        Ok(Some(&rest[..len]))
    }
}

/// Byte offset to Gumbo line and column. Lookups are mostly in order, so a
/// cursor walks forward and restarts at the line start when it must go back.
struct Lines {
    text: Rc<str>,
    starts: Vec<usize>,
    offset: usize,
    line: i32,
    column: i32,
}

impl Lines {
    fn new(text: Rc<str>) -> Self {
        let mut starts = vec![0];
        starts.extend(text.bytes().enumerate().filter(|(_, byte)| *byte == b'\n').map(|(index, _)| index + 1));
        Self { text, starts, offset: 0, line: 1, column: 1 }
    }

    fn locate(&mut self, offset: usize) -> (i32, i32) {
        if offset < self.offset {
            let line = self.starts.partition_point(|start| *start <= offset) - 1;
            self.offset = self.starts[line];
            self.line = line as i32 + 1;
            self.column = 1;
        }
        for ch in self.text[self.offset..offset].chars() {
            match ch {
                '\n' => {
                    self.line += 1;
                    self.column = 1;
                }
                '\t' => self.column = ((self.column / 8) + 1) * 8,
                _ => self.column += 1,
            }
        }
        self.offset = offset;
        (self.line, self.column)
    }
}

/// State that the tree builder changes between tokens.
#[derive(Default)]
struct Shared {
    foreign: Cell<bool>,
    too_many_attributes: Cell<bool>,
}

struct Gumbo {
    text: Rc<str>,
    lines: Lines,
    errors: Rc<RefCell<ErrorLog>>,
    shared: Rc<Shared>,
    max_attributes: i64,
    tokens: VecDeque<Token>,
    /// Byte offset that html5gum has read up to.
    position: usize,
    /// End of the last token. The next token starts here.
    last_end: usize,
    /// Input that the queued character tokens cover.
    string_cursor: usize,
    /// Bytes of a code point that html5gum split over calls.
    partial: Vec<u8>,
    cdata_end: usize,
    last_start: Vec<u8>,
    start_tag: bool,
    self_closing: bool,
    name: Vec<u8>,
    attrs: Vec<(String, String)>,
    attr_name: Vec<u8>,
    attr_value: Vec<u8>,
    in_attr: bool,
    had_attrs: bool,
    data: Vec<u8>,
    public_id: Option<Vec<u8>>,
    system_id: Option<Vec<u8>>,
    force_quirks: bool,
}

fn utf8(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

impl Gumbo {
    fn token(&mut self, kind: TokenKind, offset: usize) -> Token {
        let mut token = Token::blank(kind);
        let (line, column) = self.lines.locate(offset);
        token.line = line;
        token.column = column;
        token.byte_offset = offset as i32;
        token
    }

    /// Queue a finished non-character token that started at `last_end`.
    fn finish(&mut self, token: Token) {
        self.tokens.push_back(token);
        self.last_end = self.position;
        self.string_cursor = self.position;
    }

    fn char_token(&mut self, mut ch: char, offset: usize) {
        let kind = if offset < self.cdata_end {
            // Gumbo replaces U+0000 in CDATA. The spec keeps it.
            if ch == '\0' {
                self.add_error("unexpected-null-character", "Input contains unexpected U+0000.".into(), offset);
                ch = '\u{FFFD}';
            }
            TokenKind::Cdata
        } else {
            match ch {
                '\0' => TokenKind::Null,
                '\t' | '\n' | '\x0C' | ' ' => TokenKind::Whitespace,
                _ => TokenKind::Character,
            }
        };
        let mut token = self.token(kind, offset);
        token.data.push(ch);
        self.tokens.push_back(token);
    }

    /// Start of the code point that ends at the read position.
    fn current_offset(&self) -> usize {
        let mut offset = self.position.saturating_sub(1).min(self.text.len());
        while !self.text.is_char_boundary(offset) {
            offset -= 1;
        }
        offset
    }

    fn char_at(&self, offset: usize) -> char {
        self.text[offset..].chars().next().unwrap_or('\u{FFFD}')
    }

    fn add_error(&mut self, code: &str, message: String, offset: usize) {
        let (line, column) = self.lines.locate(offset);
        self.errors.borrow_mut().add(code, message, line, column, offset as i32);
    }

    fn reset_tag(&mut self) {
        self.name.clear();
        self.attrs.clear();
        self.attr_name.clear();
        self.attr_value.clear();
        self.in_attr = false;
        self.had_attrs = false;
        self.self_closing = false;
    }

    fn commit_attribute(&mut self) {
        if !self.in_attr {
            return;
        }
        self.in_attr = false;
        self.had_attrs = true;
        let name = utf8(&std::mem::take(&mut self.attr_name));
        let value = utf8(&std::mem::take(&mut self.attr_value));
        if self.max_attributes >= 0 && self.max_attributes <= self.attrs.len() as i64 {
            self.shared.too_many_attributes.set(true);
            return;
        }
        if self.attrs.iter().any(|(existing, _)| *existing == name) {
            let offset = self.last_end;
            self.add_error("duplicate-attribute", "Tag contains multiple attributes with the same name.".into(), offset);
            return;
        }
        self.attrs.push((name, value));
    }

    fn message(&self, error: Error, offset: usize) -> String {
        let shown = || {
            let start = self.text[..self.position.min(self.text.len())].rfind('&').unwrap_or(offset);
            self.text[start..self.position.min(self.text.len())].to_string()
        };
        let code_point = || {
            let reference = shown();
            let digits = reference.trim_start_matches("&#").trim_end_matches(';');
            match digits.strip_prefix(['x', 'X']) {
                Some(hex) => u32::from_str_radix(hex, 16).unwrap_or(0),
                None => digits.parse().unwrap_or(0),
            }
        };
        match error {
            Error::UnexpectedNullCharacter => "Input contains unexpected U+0000.".into(),
            Error::UnexpectedQuestionMarkInsteadOfTagName => "Unexpected '?' where start tag name is expected.".into(),
            Error::EofBeforeTagName => "End of input where a tag name is expected.".into(),
            Error::MissingEndTagName => "Missing end tag name.".into(),
            Error::InvalidFirstCharacterOfTagName => {
                let ch = self.char_at(offset);
                if ch.is_ascii() && !ch.is_ascii_control() {
                    format!("Invalid first character of tag name '{ch}'.")
                } else {
                    format!("Invalid first code point of tag name U+{:04X}.", ch as u32)
                }
            }
            Error::UnexpectedEqualsSignBeforeAttributeName => "Unexpected '=' before an attribute name.".into(),
            Error::UnexpectedCharacterInAttributeName => {
                format!("Unexpected character ({}) in attribute name.", self.char_at(offset))
            }
            Error::MissingAttributeValue => "Missing attribute value.".into(),
            Error::UnexpectedCharacterInUnquotedAttributeValue => {
                format!("Unexpected character ({}) in unquoted attribute value.", self.char_at(offset))
            }
            Error::MissingWhitespaceBetweenAttributes => "Missing whitespace between attributes.".into(),
            Error::UnexpectedSolidusInTag => "Unexpected '/' in tag.".into(),
            Error::EofInTag => "End of input in tag.".into(),
            Error::EofInScriptHtmlCommentLikeText => "End of input in script HTML comment-like text.".into(),
            Error::CdataInHtmlContent => "CDATA section in HTML content.".into(),
            Error::IncorrectlyOpenedComment => {
                "Comment, DOCTYPE, or CDATA opened incorrectly, use '<!--', '<!DOCTYPE', or '<![CDATA['.".into()
            }
            Error::AbruptClosingOfEmptyComment => "Empty comment abruptly closed by '>', use '-->'.".into(),
            Error::NestedComment => "Nested comment.".into(),
            Error::IncorrectlyClosedComment => "Comment closed incorrectly by '--!>', use '-->'.".into(),
            Error::EofInComment => "End of input in comment.".into(),
            Error::MissingWhitespaceBeforeDoctypeName => {
                "Missing whitespace between 'DOCTYPE' keyword and DOCTYPE name.".into()
            }
            Error::MissingDoctypeName => "Missing DOCTYPE name.".into(),
            Error::InvalidCharacterSequenceAfterDoctypeName => {
                "Invalid character sequence after DOCTYPE name, expected 'PUBLIC', 'SYSTEM', or '>'.".into()
            }
            Error::MissingWhitespaceAfterDoctypePublicKeyword => "Missing whitespace after 'PUBLIC' keyword.".into(),
            Error::MissingDoctypePublicIdentifier => "Missing DOCTYPE public identifier.".into(),
            Error::MissingQuoteBeforeDoctypePublicIdentifier => "Missing quote before DOCTYPE public identifier.".into(),
            Error::MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers => {
                "Missing whitespace between DOCTYPE public and system identifiers.".into()
            }
            Error::MissingQuoteBeforeDoctypeSystemIdentifier => "Missing quote before DOCTYPE system identifier.".into(),
            Error::MissingWhitespaceAfterDoctypeSystemKeyword => "Missing whitespace after 'SYSTEM' keyword.".into(),
            Error::MissingDoctypeSystemIdentifier => "Missing DOCTYPE system identifier.".into(),
            Error::UnexpectedCharacterAfterDoctypeSystemIdentifier => {
                "Unexpected character after DOCTYPE system identifier.".into()
            }
            Error::EofInDoctype => "End of input in DOCTYPE.".into(),
            Error::EofInCdata => "End of input in CDATA section.".into(),
            Error::MissingSemicolonAfterCharacterReference => {
                format!("Missing semicolon after character reference '{}'.", shown())
            }
            Error::UnknownNamedCharacterReference => format!("Unknown named character reference '{}'.", shown()),
            Error::AbsenceOfDigitsInNumericCharacterReference => {
                let reference = shown();
                if reference.starts_with("&#x") || reference.starts_with("&#X") {
                    format!("Numeric character reference '{reference}' does not contain any hexadecimal digits.")
                } else {
                    format!("Numeric character reference '{reference}' does not contain any digits.")
                }
            }
            Error::NullCharacterReference => format!("Numeric character reference '{}' references U+0000.", shown()),
            Error::CharacterReferenceOutsideUnicodeRange => format!(
                "Numeric character reference '{}' references a code point that is outside the valid Unicode range.",
                shown()
            ),
            Error::SurrogateCharacterReference => {
                format!("Numeric character reference '{}' references surrogate U+{:4X}.", shown(), code_point())
            }
            Error::NoncharacterCharacterReference => {
                format!("Numeric character reference '{}' references noncharacter U+{:04X}.", shown(), code_point())
            }
            Error::ControlCharacterReference => format!(
                "Numeric character reference '{}' references prohibited control code point U+{:04X}.",
                shown(),
                code_point()
            ),
            other => other.as_str().to_string(),
        }
    }
}

impl Emitter for Gumbo {
    type Token = Token;

    fn move_position(&mut self, offset: isize) {
        self.position = self.position.saturating_add_signed(offset);
    }

    fn set_last_start_tag(&mut self, last_start_tag: Option<&[u8]>) {
        self.last_start = last_start_tag.unwrap_or_default().to_vec();
    }

    fn emit_eof(&mut self) {}

    fn emit_error(&mut self, error: Error) {
        let offset = match error {
            // Gumbo reads the input as already valid.
            Error::ControlCharacterInInputStream
            | Error::NoncharacterInInputStream
            | Error::SurrogateInInputStream => return,
            Error::MissingSemicolonAfterCharacterReference
            | Error::UnknownNamedCharacterReference
            | Error::AbsenceOfDigitsInNumericCharacterReference
            | Error::NullCharacterReference
            | Error::CharacterReferenceOutsideUnicodeRange
            | Error::SurrogateCharacterReference
            | Error::NoncharacterCharacterReference
            | Error::ControlCharacterReference => {
                self.text[..self.position.min(self.text.len())].rfind('&').unwrap_or(self.position)
            }
            Error::EndTagWithAttributes | Error::EndTagWithTrailingSolidus | Error::DuplicateAttribute => {
                self.last_end
            }
            _ if error.as_str().starts_with("eof-") => self.position.min(self.text.len()),
            _ => self.current_offset(),
        };
        let message = self.message(error, offset);
        self.add_error(error.as_str(), message, offset);
    }

    fn pop_token(&mut self) -> Option<Token> {
        self.tokens.pop_front()
    }

    fn emit_string(&mut self, bytes: &[u8]) {
        let literal = self.partial.is_empty()
            && self.text.as_bytes().get(self.string_cursor..self.string_cursor + bytes.len()) == Some(bytes);
        let mut joined;
        let bytes = if self.partial.is_empty() {
            bytes
        } else {
            joined = std::mem::take(&mut self.partial);
            joined.extend_from_slice(bytes);
            &joined[..]
        };
        let (valid, rest) = match std::str::from_utf8(bytes) {
            Ok(valid) => (valid, &[][..]),
            Err(error) => {
                let (valid, rest) = bytes.split_at(error.valid_up_to());
                (std::str::from_utf8(valid).unwrap_or_default(), rest)
            }
        };
        if literal {
            let start = self.string_cursor;
            for (index, ch) in valid.char_indices() {
                self.char_token(ch, start + index);
            }
            self.string_cursor += valid.len();
        } else {
            // A character reference or a replacement. Its characters take the
            // start of the input that made them.
            let start = self.string_cursor;
            for ch in valid.chars() {
                self.char_token(ch, start);
            }
            self.string_cursor = self.position;
        }
        self.partial.extend_from_slice(rest);
        self.last_end = self.string_cursor;
    }

    fn init_start_tag(&mut self) {
        self.start_tag = true;
        self.reset_tag();
    }

    fn init_end_tag(&mut self) {
        self.start_tag = false;
        self.reset_tag();
    }

    fn init_comment(&mut self) {
        self.data.clear();
    }

    fn emit_current_tag(&mut self) -> Option<State> {
        self.commit_attribute();
        let kind = if self.start_tag { TokenKind::StartTag } else { TokenKind::EndTag };
        let mut token = self.token(kind, self.last_end);
        token.name = utf8(&self.name);
        token.self_closing = self.self_closing;
        if self.start_tag {
            token.attrs = std::mem::take(&mut self.attrs);
            self.last_start.clone_from(&self.name);
        } else {
            if self.self_closing {
                self.emit_error(Error::EndTagWithTrailingSolidus);
            }
            if self.had_attrs {
                self.emit_error(Error::EndTagWithAttributes);
            }
        }
        self.finish(token);
        None
    }

    fn emit_current_comment(&mut self) {
        let mut token = self.token(TokenKind::Comment, self.last_end);
        token.data = utf8(&self.data);
        self.finish(token);
    }

    fn emit_current_doctype(&mut self) {
        let mut token = self.token(TokenKind::Doctype, self.last_end);
        token.name = utf8(&self.name);
        token.has_public_id = self.public_id.is_some();
        token.has_system_id = self.system_id.is_some();
        token.public_id = self.public_id.take().map(|id| utf8(&id)).unwrap_or_default();
        token.system_id = self.system_id.take().map(|id| utf8(&id)).unwrap_or_default();
        token.force_quirks = self.force_quirks;
        self.finish(token);
    }

    fn set_self_closing(&mut self) {
        self.self_closing = true;
    }

    fn set_force_quirks(&mut self) {
        self.force_quirks = true;
    }

    fn push_tag_name(&mut self, s: &[u8]) {
        self.name.extend_from_slice(s);
    }

    fn push_comment(&mut self, s: &[u8]) {
        self.data.extend_from_slice(s);
    }

    fn push_doctype_name(&mut self, s: &[u8]) {
        self.name.extend_from_slice(s);
    }

    fn init_doctype(&mut self) {
        self.name.clear();
        self.public_id = None;
        self.system_id = None;
        self.force_quirks = false;
    }

    fn init_attribute(&mut self) {
        self.commit_attribute();
        self.in_attr = true;
    }

    fn push_attribute_name(&mut self, s: &[u8]) {
        self.attr_name.extend_from_slice(s);
    }

    fn push_attribute_value(&mut self, s: &[u8]) {
        self.attr_value.extend_from_slice(s);
    }

    fn set_doctype_public_identifier(&mut self, value: &[u8]) {
        self.public_id = Some(value.to_vec());
    }

    fn set_doctype_system_identifier(&mut self, value: &[u8]) {
        self.system_id = Some(value.to_vec());
    }

    fn push_doctype_public_identifier(&mut self, s: &[u8]) {
        self.public_id.get_or_insert_with(Vec::new).extend_from_slice(s);
    }

    fn push_doctype_system_identifier(&mut self, s: &[u8]) {
        self.system_id.get_or_insert_with(Vec::new).extend_from_slice(s);
    }

    fn current_is_appropriate_end_tag_token(&mut self) -> bool {
        !self.start_tag && !self.last_start.is_empty() && self.name == self.last_start
    }

    fn adjusted_current_node_present_but_not_in_html_namespace(&mut self) -> bool {
        let foreign = self.shared.foreign.get();
        if foreign {
            let start = self.position.min(self.text.len());
            self.cdata_end = self.text[start..].find("]]>").map_or(self.text.len(), |index| start + index);
            self.string_cursor = self.position;
            self.last_end = self.position;
        }
        foreign
    }
}

pub struct Tokenizer {
    inner: html5gum::Tokenizer<TextReader, Gumbo>,
    shared: Rc<Shared>,
    eof: Token,
}

impl Tokenizer {
    pub fn new(input: &str, errors: Rc<RefCell<ErrorLog>>, max_attributes: i64) -> Self {
        let text: Rc<str> = preprocess(input).into();
        let shared = Rc::new(Shared::default());
        let mut lines = Lines::new(text.clone());
        let mut eof = Token::blank(TokenKind::Eof);
        let (line, column) = lines.locate(text.len());
        eof.line = line;
        eof.column = column;
        eof.byte_offset = text.len() as i32;
        let emitter = Gumbo {
            text: text.clone(),
            lines,
            errors,
            shared: shared.clone(),
            max_attributes,
            tokens: VecDeque::new(),
            position: 0,
            last_end: 0,
            string_cursor: 0,
            partial: Vec::new(),
            cdata_end: 0,
            last_start: Vec::new(),
            start_tag: false,
            self_closing: false,
            name: Vec::new(),
            attrs: Vec::new(),
            attr_name: Vec::new(),
            attr_value: Vec::new(),
            in_attr: false,
            had_attrs: false,
            data: Vec::new(),
            public_id: None,
            system_id: None,
            force_quirks: false,
        };
        let reader = TextReader { text, at: 0 };
        Self { inner: html5gum::Tokenizer::new_with_emitter(reader, emitter), shared, eof }
    }

    pub fn set_foreign(&mut self, value: bool) {
        self.shared.foreign.set(value);
    }

    pub fn set_state(&mut self, state: TokState) {
        self.inner.set_state(match state {
            TokState::Rcdata => State::RcData,
            TokState::Rawtext => State::RawText,
            TokState::ScriptData => State::ScriptData,
            TokState::Plaintext => State::PlainText,
            TokState::Data => State::Data,
        });
    }

    pub fn next_token(&mut self) -> Token {
        match self.inner.next() {
            Some(Ok(token)) => token,
            Some(Err(never)) => match never {},
            None => self.eof.clone(),
        }
    }

    pub fn too_many_attributes(&self) -> bool {
        self.shared.too_many_attributes.get()
    }
}
