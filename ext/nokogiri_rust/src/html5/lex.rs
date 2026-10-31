//! HTML5 tokenizer. One character token is emitted for each code point.

use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

use crate::html5::entities::match_named;
use crate::html5::model::{ErrorLog, TokState, Token, TokenKind};

/// The full tokenizer state machine. The tree builder sets only the
/// five states in TokState.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum LexState {
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

impl From<TokState> for LexState {
    fn from(state: TokState) -> Self {
        match state {
            TokState::Data => LexState::Data,
            TokState::Rcdata => LexState::Rcdata,
            TokState::Rawtext => LexState::Rawtext,
            TokState::ScriptData => LexState::ScriptData,
            TokState::Plaintext => LexState::Plaintext,
        }
    }
}

const REPLACEMENT: i32 = 0xFFFD;
const MAX_CHAR: u32 = 0x10FFFF;
const EOF: i32 = -1;

struct CharPos {
    cp: i32,
    line: i32,
    column: i32,
    offset: i32,
}

#[derive(Clone, Copy)]
enum At {
    Current,
    Mark,
    Token,
}

fn cp_char(cp: i32) -> char {
    char::from_u32(cp as u32).unwrap_or('\u{FFFD}')
}

fn starts_with_ascii_ci(value: &str, needle: &str) -> bool {
    let mut chars = value.chars();
    for expected in needle.chars() {
        match chars.next() {
            Some(ch) => {
                let folded = if ch.is_ascii_uppercase() {
                    char::from_u32(ch as u32 + 32).unwrap_or(ch)
                } else {
                    ch
                };
                if folded != expected {
                    return false;
                }
            }
            None => return false,
        }
    }
    true
}

fn windows1252(value: u32) -> u32 {
    match value {
        0x80 => 0x20AC,
        0x82 => 0x201A,
        0x83 => 0x0192,
        0x84 => 0x201E,
        0x85 => 0x2026,
        0x86 => 0x2020,
        0x87 => 0x2021,
        0x88 => 0x02C6,
        0x89 => 0x2030,
        0x8A => 0x0160,
        0x8B => 0x2039,
        0x8C => 0x0152,
        0x8E => 0x017D,
        0x91 => 0x2018,
        0x92 => 0x2019,
        0x93 => 0x201C,
        0x94 => 0x201D,
        0x95 => 0x2022,
        0x96 => 0x2013,
        0x97 => 0x2014,
        0x98 => 0x02DC,
        0x99 => 0x2122,
        0x9A => 0x0161,
        0x9B => 0x203A,
        0x9C => 0x0153,
        0x9E => 0x017E,
        0x9F => 0x0178,
        _ => value,
    }
}

/// Skip a leading UTF-8 BOM, scrub invalid UTF-8, then map `\r\n?` to `\n`.
fn preprocess(input: &str) -> String {
    let raw = input.as_bytes();
    let raw = if raw.len() >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF {
        &raw[3..]
    } else {
        raw
    };
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

pub struct Tokenizer {
    errors: Rc<RefCell<ErrorLog>>,
    max_attributes: i64,
    too_many_attributes: bool,
    state: LexState,
    return_state: LexState,
    foreign: bool,
    in_cdata: bool,
    reconsume: bool,
    buffered: Option<i32>,
    pending_token: Option<Token>,
    resume: Option<usize>,
    mark: usize,
    token_start: usize,
    last_start: Option<String>,
    buffer: String,
    temporary: String,
    drop_attr: bool,
    ref_value: u32,
    text: String,
    chars: Vec<CharPos>,
    eof_line: i32,
    eof_column: i32,
    eof_offset: i32,
    index: usize,
    start_tag: bool,
    attrs: Vec<(String, String)>,
    attr_names: HashSet<String>,
    self_closing: bool,
    name: String,
    doctype_name: String,
    doctype_public_id: String,
    doctype_system_id: String,
    doctype_has_public_id: bool,
    doctype_has_system_id: bool,
    doctype_force_quirks: bool,
}

impl Tokenizer {
    pub fn new(input: &str, errors: Rc<RefCell<ErrorLog>>, max_attributes: i64) -> Self {
        let mut tokenizer = Self {
            errors,
            max_attributes,
            too_many_attributes: false,
            state: LexState::Data,
            return_state: LexState::Data,
            foreign: false,
            in_cdata: false,
            reconsume: false,
            buffered: None,
            pending_token: None,
            resume: None,
            mark: 0,
            token_start: 0,
            last_start: None,
            buffer: String::new(),
            temporary: String::new(),
            drop_attr: false,
            ref_value: 0,
            text: String::new(),
            chars: Vec::new(),
            eof_line: 1,
            eof_column: 1,
            eof_offset: 0,
            index: 0,
            start_tag: false,
            attrs: Vec::new(),
            attr_names: HashSet::new(),
            self_closing: false,
            name: String::new(),
            doctype_name: String::new(),
            doctype_public_id: String::new(),
            doctype_system_id: String::new(),
            doctype_has_public_id: false,
            doctype_has_system_id: false,
            doctype_force_quirks: false,
        };
        tokenizer.load(input);
        tokenizer
    }

    pub fn set_foreign(&mut self, value: bool) {
        self.foreign = value;
    }

    pub fn set_state(&mut self, state: TokState) {
        self.state = state.into();
    }

    pub fn next_token(&mut self) -> Token {
        if let Some(token) = self.pending_token.take() {
            return token;
        }
        if let Some(token) = self.take_buffered() {
            return token;
        }
        if self.emit_resume() {
            let cp = self.current_cp();
            return self.char_token(cp);
        }

        loop {
            let cp = self.current_cp();
            let token = self.dispatch(cp);
            let advance = !self.reconsume;
            self.reconsume = false;
            if let Some(token) = token {
                return token;
            }
            if advance {
                self.step();
            }
        }
    }

    pub fn too_many_attributes(&self) -> bool {
        self.too_many_attributes
    }

    fn load(&mut self, input: &str) {
        let text = preprocess(input);
        let mut chars = Vec::with_capacity(text.len());
        let mut line: i32 = 1;
        let mut column: i32 = 1;
        let mut offset: i32 = 0;
        for ch in text.chars() {
            chars.push(CharPos {
                cp: ch as i32,
                line,
                column,
                offset,
            });
            offset += ch.len_utf8() as i32;
            if ch == '\n' {
                line += 1;
                column = 1;
            } else if ch == '\t' {
                column = ((column / 8) + 1) * 8;
            } else {
                column += 1;
            }
        }
        self.eof_line = line;
        self.eof_column = column;
        self.eof_offset = offset;
        self.text = text;
        self.chars = chars;
        self.index = 0;
    }

    fn dispatch(&mut self, cp: i32) -> Option<Token> {
        let state = self.state;
        match state {
            LexState::Data => self.data(cp),
            LexState::Rcdata => self.rcdata(cp),
            LexState::Rawtext => self.rawtext(cp),
            LexState::ScriptData => self.script_data(cp),
            LexState::Plaintext => self.plaintext(cp),
            LexState::TagOpen => self.tag_open(cp),
            LexState::EndTagOpen => self.end_tag_open(cp),
            LexState::TagName => self.tag_name(cp),
            LexState::BeforeAttrName => self.before_attr_name(cp),
            LexState::AttrName => self.attr_name(cp),
            LexState::AfterAttrName => self.after_attr_name(cp),
            LexState::BeforeAttrValue => self.before_attr_value(cp),
            LexState::AttrDouble => self.attr_double(cp),
            LexState::AttrSingle => self.attr_single(cp),
            LexState::AttrUnquoted => self.attr_unquoted(cp),
            LexState::AfterAttrValue => self.after_attr_value(cp),
            LexState::SelfClosing => self.self_closing(cp),
            LexState::RcdataLt => self.rcdata_lt(cp),
            LexState::RcdataEndOpen => self.rcdata_end_open(cp),
            LexState::RcdataEndName => self.rcdata_end_name(cp),
            LexState::RawtextLt => self.rawtext_lt(cp),
            LexState::RawtextEndOpen => self.rawtext_end_open(cp),
            LexState::RawtextEndName => self.rawtext_end_name(cp),
            LexState::ScriptLt => self.script_lt(cp),
            LexState::ScriptEndOpen => self.script_end_open(cp),
            LexState::ScriptEndName => self.script_end_name(cp),
            LexState::ScriptEscapedStart => self.script_escaped_start(cp),
            LexState::ScriptEscapedStartDash => self.script_escaped_start_dash(cp),
            LexState::ScriptEscaped => self.script_escaped(cp),
            LexState::ScriptEscapedDash => self.script_escaped_dash(cp),
            LexState::ScriptEscapedDashDash => self.script_escaped_dash_dash(cp),
            LexState::ScriptEscapedLt => self.script_escaped_lt(cp),
            LexState::ScriptEscapedEndOpen => self.script_escaped_end_open(cp),
            LexState::ScriptEscapedEndName => self.script_escaped_end_name(cp),
            LexState::ScriptDoubleEscapedStart => self.script_double_escaped_start(cp),
            LexState::ScriptDoubleEscaped => self.script_double_escaped(cp),
            LexState::ScriptDoubleEscapedDash => self.script_double_escaped_dash(cp),
            LexState::ScriptDoubleEscapedDashDash => self.script_double_escaped_dash_dash(cp),
            LexState::ScriptDoubleEscapedLt => self.script_double_escaped_lt(cp),
            LexState::ScriptDoubleEscapedEnd => self.script_double_escaped_end(cp),
            LexState::BogusComment => self.bogus_comment(cp),
            LexState::MarkupDeclaration => self.markup_declaration(cp),
            LexState::CommentStart => self.comment_start(cp),
            LexState::CommentStartDash => self.comment_start_dash(cp),
            LexState::Comment => self.comment(cp),
            LexState::CommentLt => self.comment_lt(cp),
            LexState::CommentLtBang => self.comment_lt_bang(cp),
            LexState::CommentLtBangDash => self.comment_lt_bang_dash(cp),
            LexState::CommentLtBangDashDash => self.comment_lt_bang_dash_dash(cp),
            LexState::CommentEndDash => self.comment_end_dash(cp),
            LexState::CommentEnd => self.comment_end(cp),
            LexState::CommentEndBang => self.comment_end_bang(cp),
            LexState::Doctype => self.doctype(cp),
            LexState::BeforeDoctypeName => self.before_doctype_name(cp),
            LexState::DoctypeName => self.doctype_name(cp),
            LexState::AfterDoctypeName => self.after_doctype_name(cp),
            LexState::AfterDoctypePublic => self.after_doctype_public(cp),
            LexState::BeforeDoctypePublic => self.before_doctype_public(cp),
            LexState::DoctypePublicDouble => self.doctype_public_double(cp),
            LexState::DoctypePublicSingle => self.doctype_public_single(cp),
            LexState::AfterDoctypePublicId => self.after_doctype_public_id(cp),
            LexState::BetweenDoctypeIds => self.between_doctype_ids(cp),
            LexState::AfterDoctypeSystem => self.after_doctype_system(cp),
            LexState::BeforeDoctypeSystem => self.before_doctype_system(cp),
            LexState::DoctypeSystemDouble => self.doctype_system_double(cp),
            LexState::DoctypeSystemSingle => self.doctype_system_single(cp),
            LexState::AfterDoctypeSystemId => self.after_doctype_system_id(cp),
            LexState::BogusDoctype => self.bogus_doctype(cp),
            LexState::Cdata => self.cdata(cp),
            LexState::CdataBracket => self.cdata_bracket(cp),
            LexState::CdataEnd => self.cdata_end(cp),
            LexState::CharacterReference => self.character_reference(cp),
            LexState::NamedReference => self.named_reference(cp),
            LexState::AmbiguousAmpersand => self.ambiguous_ampersand(cp),
            LexState::NumericReference => self.numeric_reference(cp),
            LexState::HexStart => self.hex_start(cp),
            LexState::DecStart => self.dec_start(cp),
            LexState::HexRef => self.hex_ref(cp),
            LexState::DecRef => self.dec_ref(cp),
            LexState::NumericEnd => self.numeric_end(cp),
        }
    }

    fn current_cp(&self) -> i32 {
        if self.index < self.chars.len() {
            self.chars[self.index].cp
        } else {
            EOF
        }
    }

    fn current_pos(&self) -> (i32, i32, i32) {
        self.pos_of(self.index)
    }

    fn step(&mut self) {
        if self.index < self.chars.len() {
            self.index += 1;
        }
    }

    fn reconsume(&mut self, next_state: LexState) {
        self.reconsume = true;
        self.state = next_state;
    }

    fn go(&mut self, next_state: LexState) {
        self.state = next_state;
    }

    fn mark(&mut self) {
        self.mark = self.index;
    }

    fn reset_token_start(&mut self) {
        self.token_start = self.index;
    }

    fn space(&self, cp: i32) -> bool {
        cp == 9 || cp == 10 || cp == 12 || cp == 32
    }

    fn alpha(&self, cp: i32) -> bool {
        (65..=90).contains(&cp) || (97..=122).contains(&cp)
    }

    fn digit(&self, cp: i32) -> bool {
        (48..=57).contains(&cp)
    }

    fn alnum(&self, cp: i32) -> bool {
        self.alpha(cp) || self.digit(cp)
    }

    fn lower(&self, cp: i32) -> i32 {
        if (65..=90).contains(&cp) {
            cp + 32
        } else {
            cp
        }
    }

    fn ascii(&self, cp: i32) -> bool {
        (0..=127).contains(&cp)
    }

    fn control(&self, cp: i32) -> bool {
        (0..=0x1F).contains(&cp) || cp == 0x7F
    }

    fn c1_control(&self, cp: i32) -> bool {
        (0x80..=0x9F).contains(&cp)
    }

    fn error(&mut self, code: &str, message: impl Into<String>, at: At) {
        let (line, column, offset) = self.position_at(at);
        self.errors
            .borrow_mut()
            .add(code, message.into(), line, column, offset);
    }

    fn position_at(&self, at: At) -> (i32, i32, i32) {
        match at {
            At::Mark => self.pos_of(self.mark),
            At::Token => self.pos_of(self.token_start),
            At::Current => self.current_pos(),
        }
    }

    fn pos_of(&self, index: usize) -> (i32, i32, i32) {
        if let Some(ch) = self.chars.get(index) {
            (ch.line, ch.column, ch.offset)
        } else {
            (self.eof_line, self.eof_column, self.eof_offset)
        }
    }

    fn slice(&self, from: usize, to: usize) -> String {
        if from >= self.chars.len() {
            return String::new();
        }
        let start = self.chars[from].offset as usize;
        let finish = if to >= self.chars.len() {
            self.text.len()
        } else {
            self.chars[to].offset as usize
        };
        self.text[start..finish].to_string()
    }

    fn start_pos(&self) -> (i32, i32, i32) {
        self.pos_of(self.token_start)
    }

    fn char_token(&mut self, cp: i32) -> Token {
        let kind = if cp == EOF {
            TokenKind::Eof
        } else if self.in_cdata {
            TokenKind::Cdata
        } else if cp == 0 {
            TokenKind::Null
        } else if self.space(cp) {
            TokenKind::Whitespace
        } else {
            TokenKind::Character
        };
        let mut token = Token::blank(kind);
        if cp != EOF {
            token.data.push(cp_char(cp));
        }
        let (line, column, byte_offset) = self.start_pos();
        token.line = line;
        token.column = column;
        token.byte_offset = byte_offset;
        self.finish_token();
        token
    }

    fn finish_token(&mut self) {
        if !self.reconsume {
            self.step();
        }
        self.reset_token_start();
    }

    fn emit_char(&mut self, cp: i32) -> Token {
        self.char_token(cp)
    }

    fn emit_cdata(&mut self, cp: i32) -> Token {
        let mut token = self.emit_char(cp);
        if cp != EOF {
            token.kind = TokenKind::Cdata;
        }
        token
    }

    fn emit_replacement(&mut self) -> Token {
        self.unexpected_null();
        self.emit_char(REPLACEMENT)
    }

    fn emit_eof(&mut self) -> Token {
        self.emit_char(EOF)
    }

    fn unexpected_null(&mut self) {
        self.error(
            "unexpected-null-character",
            "Input contains unexpected U+0000.",
            At::Current,
        );
    }

    fn take_buffered(&mut self) -> Option<Token> {
        let cp = self.buffered.take()?;
        self.reconsume = true;
        let token = self.emit_char(cp);
        self.reconsume = false;
        Some(token)
    }

    fn emit_resume(&mut self) -> bool {
        let Some(resume) = self.resume else {
            return false;
        };
        if self.index >= resume {
            return false;
        }
        if self.index + 1 >= resume {
            self.resume = None;
        }
        true
    }

    fn emit_from_mark(&mut self) -> Token {
        let saved = self.index;
        self.resume = Some(saved);
        self.index = self.mark;
        self.reconsume = false;
        if self.index + 1 >= saved {
            self.resume = None;
        }
        let cp = self.current_cp();
        self.emit_char(cp)
    }

    fn data(&mut self, cp: i32) -> Option<Token> {
        match cp {
            38 => {
                self.go(LexState::CharacterReference);
                self.mark();
                self.return_state = LexState::Data;
                None
            }
            60 => {
                self.go(LexState::TagOpen);
                self.mark();
                None
            }
            0 => {
                self.unexpected_null();
                Some(self.emit_char(cp))
            }
            EOF => Some(self.emit_eof()),
            _ => Some(self.emit_char(cp)),
        }
    }

    fn rcdata(&mut self, cp: i32) -> Option<Token> {
        match cp {
            38 => {
                self.go(LexState::CharacterReference);
                self.mark();
                self.return_state = LexState::Rcdata;
                None
            }
            60 => {
                self.go(LexState::RcdataLt);
                self.mark();
                None
            }
            0 => Some(self.emit_replacement()),
            EOF => Some(self.emit_eof()),
            _ => Some(self.emit_char(cp)),
        }
    }

    fn rawtext(&mut self, cp: i32) -> Option<Token> {
        match cp {
            60 => {
                self.go(LexState::RawtextLt);
                self.mark();
                None
            }
            0 => Some(self.emit_replacement()),
            EOF => Some(self.emit_eof()),
            _ => Some(self.emit_char(cp)),
        }
    }

    fn script_data(&mut self, cp: i32) -> Option<Token> {
        match cp {
            60 => {
                self.go(LexState::ScriptLt);
                self.mark();
                None
            }
            0 => Some(self.emit_replacement()),
            EOF => Some(self.emit_eof()),
            _ => Some(self.emit_char(cp)),
        }
    }

    fn plaintext(&mut self, cp: i32) -> Option<Token> {
        match cp {
            0 => Some(self.emit_replacement()),
            EOF => Some(self.emit_eof()),
            _ => Some(self.emit_char(cp)),
        }
    }

    fn tag_open(&mut self, cp: i32) -> Option<Token> {
        match cp {
            33 => {
                self.go(LexState::MarkupDeclaration);
                self.temporary.clear();
                None
            }
            47 => {
                self.go(LexState::EndTagOpen);
                None
            }
            63 => {
                self.error(
                    "unexpected-question-mark-instead-of-tag-name",
                    "Unexpected '?' where start tag name is expected.",
                    At::Current,
                );
                self.temporary.clear();
                self.reconsume(LexState::BogusComment);
                None
            }
            EOF => {
                self.error(
                    "eof-before-tag-name",
                    "End of input where a tag name is expected.",
                    At::Current,
                );
                self.reconsume(LexState::Data);
                Some(self.emit_from_mark())
            }
            _ => {
                if self.alpha(cp) {
                    self.reconsume(LexState::TagName);
                    self.start_tag(true);
                    None
                } else {
                    self.invalid_first(cp);
                    self.reconsume(LexState::Data);
                    Some(self.emit_from_mark())
                }
            }
        }
    }

    fn end_tag_open(&mut self, cp: i32) -> Option<Token> {
        match cp {
            62 => {
                self.error("missing-end-tag-name", "Missing end tag name.", At::Current);
                self.go(LexState::Data);
                None
            }
            EOF => {
                self.error(
                    "eof-before-tag-name",
                    "End of input where a tag name is expected.",
                    At::Current,
                );
                self.reconsume(LexState::Data);
                Some(self.emit_from_mark())
            }
            _ => {
                if self.alpha(cp) {
                    self.reconsume(LexState::TagName);
                    self.start_tag(false);
                } else {
                    self.invalid_first(cp);
                    self.reconsume(LexState::BogusComment);
                    self.temporary.clear();
                }
                None
            }
        }
    }

    fn invalid_first(&mut self, cp: i32) {
        let message = if self.ascii(cp) && !self.control(cp) {
            format!("Invalid first character of tag name '{}'.", cp_char(cp))
        } else {
            format!("Invalid first code point of tag name U+{:04X}.", cp as u32)
        };
        self.error("invalid-first-character-of-tag-name", message, At::Current);
    }

    fn tag_name(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            self.finish_name();
            self.go(LexState::BeforeAttrName);
            return None;
        }
        match cp {
            47 => {
                self.finish_name();
                self.go(LexState::SelfClosing);
                None
            }
            62 => {
                self.finish_name();
                self.go(LexState::Data);
                Some(self.emit_tag())
            }
            0 => {
                self.unexpected_null();
                self.buffer.push('\u{FFFD}');
                None
            }
            EOF => Some(self.eof_in_tag()),
            _ => {
                let lowered = self.lower(cp);
                self.buffer.push(cp_char(lowered));
                None
            }
        }
    }

    fn start_tag(&mut self, start_tag: bool) {
        self.start_tag = start_tag;
        self.buffer.clear();
        self.attrs.clear();
        self.attr_names.clear();
        self.self_closing = false;
        self.drop_attr = false;
    }

    fn finish_name(&mut self) {
        self.name = std::mem::take(&mut self.buffer);
    }

    fn finish_attribute_name(&mut self) {
        let count = self.attrs.len() as i64;
        if self.max_attributes >= 0 && self.max_attributes <= count {
            self.too_many_attributes = true;
            self.buffer.clear();
            self.drop_attr = true;
            return;
        }

        let name = std::mem::take(&mut self.buffer);
        if self.attr_names.contains(&name) {
            self.error(
                "duplicate-attribute",
                "Tag contains multiple attributes with the same name.",
                At::Token,
            );
            self.drop_attr = true;
            return;
        }

        self.drop_attr = false;
        self.attr_names.insert(name.clone());
        self.attrs.push((name, String::new()));
    }

    fn finish_attribute_value(&mut self) {
        if self.drop_attr {
            self.drop_attr = false;
            self.buffer.clear();
            return;
        }
        if let Some(attr) = self.attrs.last_mut() {
            attr.1 = std::mem::take(&mut self.buffer);
        } else {
            self.buffer.clear();
        }
    }

    fn appropriate_end(&self) -> bool {
        !self.start_tag && self.last_start.as_deref() == Some(self.buffer.as_str())
    }

    fn emit_tag(&mut self) -> Token {
        let (line, column, byte_offset) = self.start_pos();
        let token = if self.start_tag {
            self.last_start = Some(self.name.clone());
            let mut token = Token::blank(TokenKind::StartTag);
            token.name.clone_from(&self.name);
            token.attrs.clone_from(&self.attrs);
            token.self_closing = self.self_closing;
            token.line = line;
            token.column = column;
            token.byte_offset = byte_offset;
            token
        } else {
            if self.self_closing {
                self.error(
                    "end-tag-with-trailing-solidus",
                    "End tag ends with '/>', use '>'.",
                    At::Token,
                );
            }
            if !self.attrs.is_empty() {
                self.error(
                    "end-tag-with-attributes",
                    "End tag contains attributes.",
                    At::Token,
                );
            }
            let mut token = Token::blank(TokenKind::EndTag);
            token.name.clone_from(&self.name);
            token.self_closing = self.self_closing;
            token.line = line;
            token.column = column;
            token.byte_offset = byte_offset;
            token
        };
        self.finish_token();
        token
    }

    fn before_attr_name(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        if cp == 47 || cp == 62 || cp == EOF {
            self.reconsume(LexState::AfterAttrName);
            return None;
        }
        if cp == 61 {
            self.error(
                "unexpected-equals-sign-before-attribute-name",
                "Unexpected '=' before an attribute name.",
                At::Current,
            );
            self.go(LexState::AttrName);
            self.buffer.push('=');
            return None;
        }
        self.reconsume(LexState::AttrName);
        None
    }

    fn attr_name(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) || cp == 47 || cp == 62 || cp == EOF {
            self.finish_attribute_name();
            self.reconsume(LexState::AfterAttrName);
            return None;
        }
        if cp == 61 {
            self.finish_attribute_name();
            self.go(LexState::BeforeAttrValue);
            return None;
        }
        if cp == 0 {
            self.unexpected_null();
            self.buffer.push('\u{FFFD}');
            return None;
        }
        if cp == 34 || cp == 39 || cp == 60 {
            self.error(
                "unexpected-character-in-attribute-name",
                format!("Unexpected character ({}) in attribute name.", cp_char(cp)),
                At::Current,
            );
        }
        let lowered = self.lower(cp);
        self.buffer.push(cp_char(lowered));
        None
    }

    fn after_attr_name(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        match cp {
            47 => {
                self.go(LexState::SelfClosing);
                None
            }
            61 => {
                self.go(LexState::BeforeAttrValue);
                None
            }
            62 => {
                self.go(LexState::Data);
                Some(self.emit_tag())
            }
            EOF => Some(self.eof_in_tag()),
            _ => {
                self.reconsume(LexState::AttrName);
                None
            }
        }
    }

    fn before_attr_value(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        match cp {
            34 => {
                self.go(LexState::AttrDouble);
                self.buffer.clear();
                None
            }
            39 => {
                self.go(LexState::AttrSingle);
                self.buffer.clear();
                None
            }
            62 => {
                self.error(
                    "missing-attribute-value",
                    "Missing attribute value.",
                    At::Current,
                );
                self.go(LexState::Data);
                Some(self.emit_tag())
            }
            _ => {
                self.reconsume(LexState::AttrUnquoted);
                None
            }
        }
    }

    fn attr_double(&mut self, cp: i32) -> Option<Token> {
        self.quoted_attr(cp, 34, LexState::AttrDouble)
    }

    fn attr_single(&mut self, cp: i32) -> Option<Token> {
        self.quoted_attr(cp, 39, LexState::AttrSingle)
    }

    fn quoted_attr(&mut self, cp: i32, quote: i32, return_state: LexState) -> Option<Token> {
        match cp {
            value if value == quote => {
                self.go(LexState::AfterAttrValue);
                None
            }
            38 => {
                self.go(LexState::CharacterReference);
                self.mark();
                self.return_state = return_state;
                None
            }
            0 => {
                self.unexpected_null();
                self.buffer.push('\u{FFFD}');
                None
            }
            EOF => Some(self.eof_in_tag()),
            _ => {
                self.buffer.push(cp_char(cp));
                None
            }
        }
    }

    fn attr_unquoted(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            self.go(LexState::BeforeAttrName);
            self.finish_attribute_value();
            return None;
        }
        match cp {
            38 => {
                self.go(LexState::CharacterReference);
                self.mark();
                self.return_state = LexState::AttrUnquoted;
                None
            }
            62 => {
                self.go(LexState::Data);
                self.finish_attribute_value();
                Some(self.emit_tag())
            }
            0 => {
                self.unexpected_null();
                self.buffer.push('\u{FFFD}');
                None
            }
            EOF => Some(self.eof_in_tag()),
            _ => {
                if cp == 34 || cp == 39 || cp == 60 || cp == 61 || cp == 96 {
                    self.error(
                        "unexpected-character-in-unquoted-attribute-value",
                        format!(
                            "Unexpected character ({}) in unquoted attribute value.",
                            cp_char(cp)
                        ),
                        At::Current,
                    );
                }
                self.buffer.push(cp_char(cp));
                None
            }
        }
    }

    fn after_attr_value(&mut self, cp: i32) -> Option<Token> {
        self.finish_attribute_value();
        if self.space(cp) {
            self.go(LexState::BeforeAttrName);
            return None;
        }
        match cp {
            47 => {
                self.go(LexState::SelfClosing);
                None
            }
            62 => {
                self.go(LexState::Data);
                Some(self.emit_tag())
            }
            EOF => Some(self.eof_in_tag()),
            _ => {
                self.error(
                    "missing-whitespace-between-attributes",
                    "Missing whitespace between attributes.",
                    At::Current,
                );
                self.reconsume(LexState::BeforeAttrName);
                None
            }
        }
    }

    fn self_closing(&mut self, cp: i32) -> Option<Token> {
        match cp {
            62 => {
                self.self_closing = true;
                self.go(LexState::Data);
                Some(self.emit_tag())
            }
            EOF => Some(self.eof_in_tag()),
            _ => {
                self.error(
                    "unexpected-solidus-in-tag",
                    "Unexpected '/' in tag.",
                    At::Current,
                );
                self.reconsume(LexState::BeforeAttrName);
                None
            }
        }
    }

    fn eof_in_tag(&mut self) -> Token {
        self.error("eof-in-tag", "End of input in tag.", At::Current);
        self.emit_eof()
    }

    fn rcdata_lt(&mut self, cp: i32) -> Option<Token> {
        if cp == 47 {
            self.go(LexState::RcdataEndOpen);
            None
        } else {
            self.reconsume(LexState::Rcdata);
            Some(self.emit_from_mark())
        }
    }

    fn rcdata_end_open(&mut self, cp: i32) -> Option<Token> {
        self.end_open(cp, LexState::Rcdata, LexState::RcdataEndName)
    }

    fn rawtext_lt(&mut self, cp: i32) -> Option<Token> {
        if cp == 47 {
            self.go(LexState::RawtextEndOpen);
            None
        } else {
            self.reconsume(LexState::Rawtext);
            Some(self.emit_from_mark())
        }
    }

    fn rawtext_end_open(&mut self, cp: i32) -> Option<Token> {
        self.end_open(cp, LexState::Rawtext, LexState::RawtextEndName)
    }

    fn script_lt(&mut self, cp: i32) -> Option<Token> {
        if cp == 47 {
            self.go(LexState::ScriptEndOpen);
            return None;
        }
        if cp == 33 {
            self.step();
            self.temporary.clear();
            self.go(LexState::ScriptEscapedStart);
            return Some(self.emit_from_mark());
        }
        self.reconsume(LexState::ScriptData);
        Some(self.emit_from_mark())
    }

    fn script_end_open(&mut self, cp: i32) -> Option<Token> {
        self.end_open(cp, LexState::ScriptData, LexState::ScriptEndName)
    }

    fn end_open(&mut self, cp: i32, back: LexState, name_state: LexState) -> Option<Token> {
        if self.alpha(cp) {
            self.buffer.clear();
            self.reconsume(name_state);
            self.start_tag(false);
            None
        } else {
            self.reconsume(back);
            Some(self.emit_from_mark())
        }
    }

    fn rcdata_end_name(&mut self, cp: i32) -> Option<Token> {
        self.end_name(cp, LexState::Rcdata)
    }

    fn rawtext_end_name(&mut self, cp: i32) -> Option<Token> {
        self.end_name(cp, LexState::Rawtext)
    }

    fn script_end_name(&mut self, cp: i32) -> Option<Token> {
        self.end_name(cp, LexState::ScriptData)
    }

    fn end_name(&mut self, cp: i32, back: LexState) -> Option<Token> {
        if self.appropriate_end() {
            if self.space(cp) {
                self.finish_name();
                self.go(LexState::BeforeAttrName);
                return None;
            } else if cp == 47 {
                self.finish_name();
                self.go(LexState::SelfClosing);
                return None;
            } else if cp == 62 {
                self.finish_name();
                self.go(LexState::Data);
                return Some(self.emit_tag());
            }
        }
        if self.alpha(cp) {
            let lowered = self.lower(cp);
            self.buffer.push(cp_char(lowered));
            return None;
        }
        self.reconsume(back);
        Some(self.emit_from_mark())
    }

    fn script_escaped_start(&mut self, cp: i32) -> Option<Token> {
        if cp == 45 {
            self.go(LexState::ScriptEscapedStartDash);
            return Some(self.emit_char(cp));
        }
        self.reconsume(LexState::ScriptData);
        None
    }

    fn script_escaped_start_dash(&mut self, cp: i32) -> Option<Token> {
        if cp == 45 {
            self.go(LexState::ScriptEscapedDashDash);
            return Some(self.emit_char(cp));
        }
        self.reconsume(LexState::ScriptData);
        None
    }

    fn script_escaped(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.go(LexState::ScriptEscapedDash);
                Some(self.emit_char(cp))
            }
            60 => {
                self.go(LexState::ScriptEscapedLt);
                self.temporary.clear();
                self.mark();
                None
            }
            0 => Some(self.emit_replacement()),
            EOF => Some(self.script_eof()),
            _ => Some(self.emit_char(cp)),
        }
    }

    fn script_escaped_dash(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.go(LexState::ScriptEscapedDashDash);
                Some(self.emit_char(cp))
            }
            60 => {
                self.go(LexState::ScriptEscapedLt);
                self.temporary.clear();
                self.mark();
                None
            }
            0 => {
                self.go(LexState::ScriptEscaped);
                Some(self.emit_replacement())
            }
            EOF => Some(self.script_eof()),
            _ => {
                self.go(LexState::ScriptEscaped);
                Some(self.emit_char(cp))
            }
        }
    }

    fn script_escaped_dash_dash(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => Some(self.emit_char(cp)),
            60 => {
                self.go(LexState::ScriptEscapedLt);
                self.temporary.clear();
                self.mark();
                None
            }
            62 => {
                self.go(LexState::ScriptData);
                Some(self.emit_char(cp))
            }
            0 => {
                self.go(LexState::ScriptEscaped);
                Some(self.emit_replacement())
            }
            EOF => Some(self.script_eof()),
            _ => {
                self.go(LexState::ScriptEscaped);
                Some(self.emit_char(cp))
            }
        }
    }

    fn script_escaped_lt(&mut self, cp: i32) -> Option<Token> {
        if cp == 47 {
            self.go(LexState::ScriptEscapedEndOpen);
            return None;
        }
        if self.alpha(cp) {
            self.reconsume(LexState::ScriptDoubleEscapedStart);
        } else {
            self.reconsume(LexState::ScriptEscaped);
        }
        Some(self.emit_from_mark())
    }

    fn script_escaped_end_open(&mut self, cp: i32) -> Option<Token> {
        self.end_open(cp, LexState::ScriptEscaped, LexState::ScriptEscapedEndName)
    }

    fn script_escaped_end_name(&mut self, cp: i32) -> Option<Token> {
        self.end_name(cp, LexState::ScriptEscaped)
    }

    fn script_double_escaped_start(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) || cp == 47 || cp == 62 {
            if self.temporary == "script" {
                self.go(LexState::ScriptDoubleEscaped);
            } else {
                self.go(LexState::ScriptEscaped);
            }
            return Some(self.emit_char(cp));
        }
        if self.alpha(cp) {
            let lowered = self.lower(cp);
            self.temporary.push(cp_char(lowered));
            return Some(self.emit_char(cp));
        }
        self.reconsume(LexState::ScriptEscaped);
        None
    }

    fn script_double_escaped(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.go(LexState::ScriptDoubleEscapedDash);
                Some(self.emit_char(cp))
            }
            60 => {
                self.go(LexState::ScriptDoubleEscapedLt);
                Some(self.emit_char(cp))
            }
            0 => Some(self.emit_replacement()),
            EOF => Some(self.script_eof()),
            _ => Some(self.emit_char(cp)),
        }
    }

    fn script_double_escaped_dash(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.go(LexState::ScriptDoubleEscapedDashDash);
                Some(self.emit_char(cp))
            }
            60 => {
                self.go(LexState::ScriptDoubleEscapedLt);
                Some(self.emit_char(cp))
            }
            0 => {
                self.go(LexState::ScriptDoubleEscaped);
                Some(self.emit_replacement())
            }
            EOF => Some(self.script_eof()),
            _ => {
                self.go(LexState::ScriptDoubleEscaped);
                Some(self.emit_char(cp))
            }
        }
    }

    fn script_double_escaped_dash_dash(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => Some(self.emit_char(cp)),
            60 => {
                self.go(LexState::ScriptDoubleEscapedLt);
                Some(self.emit_char(cp))
            }
            62 => {
                self.go(LexState::ScriptData);
                Some(self.emit_char(cp))
            }
            0 => {
                self.go(LexState::ScriptDoubleEscaped);
                Some(self.emit_replacement())
            }
            EOF => Some(self.script_eof()),
            _ => {
                self.go(LexState::ScriptDoubleEscaped);
                Some(self.emit_char(cp))
            }
        }
    }

    fn script_double_escaped_lt(&mut self, cp: i32) -> Option<Token> {
        if cp == 47 {
            self.go(LexState::ScriptDoubleEscapedEnd);
            self.temporary.clear();
            return Some(self.emit_char(cp));
        }
        self.reconsume(LexState::ScriptDoubleEscaped);
        None
    }

    fn script_double_escaped_end(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) || cp == 47 || cp == 62 {
            if self.temporary == "script" {
                self.go(LexState::ScriptEscaped);
            } else {
                self.go(LexState::ScriptDoubleEscaped);
            }
            return Some(self.emit_char(cp));
        }
        if self.alpha(cp) {
            let lowered = self.lower(cp);
            self.temporary.push(cp_char(lowered));
            return Some(self.emit_char(cp));
        }
        self.reconsume(LexState::ScriptDoubleEscaped);
        None
    }

    fn script_eof(&mut self) -> Token {
        self.error(
            "eof-in-script-html-comment-like-text",
            "End of input in script HTML comment-like text.",
            At::Current,
        );
        self.emit_eof()
    }

    fn bogus_comment(&mut self, cp: i32) -> Option<Token> {
        match cp {
            62 => {
                self.go(LexState::Data);
                Some(self.emit_comment())
            }
            EOF => {
                self.reconsume(LexState::Data);
                Some(self.emit_comment())
            }
            0 => {
                self.unexpected_null();
                self.temporary.push('\u{FFFD}');
                None
            }
            _ => {
                self.temporary.push(cp_char(cp));
                None
            }
        }
    }

    fn emit_comment(&mut self) -> Token {
        let (line, column, byte_offset) = self.start_pos();
        let mut token = Token::blank(TokenKind::Comment);
        token.data = std::mem::take(&mut self.temporary);
        token.line = line;
        token.column = column;
        token.byte_offset = byte_offset;
        self.finish_token();
        token
    }

    fn markup_declaration(&mut self, _cp: i32) -> Option<Token> {
        let upcoming = self.slice(self.index, self.index.saturating_add(7));
        if upcoming.starts_with("--") {
            self.index += 2;
            self.temporary.clear();
            self.reconsume(LexState::CommentStart);
            return None;
        }
        if starts_with_ascii_ci(&upcoming, "doctype") {
            self.index += 7;
            self.reconsume(LexState::Doctype);
            return None;
        }
        if upcoming.starts_with("[CDATA[") {
            if self.foreign {
                self.index += 7;
                self.in_cdata = true;
                self.reconsume(LexState::Cdata);
            } else {
                self.error(
                    "cdata-in-html-content",
                    "CDATA section in HTML content.",
                    At::Current,
                );
                self.temporary.clear();
                self.reconsume(LexState::BogusComment);
            }
            return None;
        }
        self.error(
            "incorrectly-opened-comment",
            "Comment, DOCTYPE, or CDATA opened incorrectly, use '<!--', '<!DOCTYPE', or '<![CDATA['.",
            At::Current,
        );
        self.reconsume(LexState::BogusComment);
        self.temporary.clear();
        None
    }

    fn comment_start(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.go(LexState::CommentStartDash);
                None
            }
            62 => {
                self.error(
                    "abrupt-closing-of-empty-comment",
                    "Empty comment abruptly closed by '>', use '-->'.",
                    At::Current,
                );
                self.go(LexState::Data);
                Some(self.emit_comment())
            }
            _ => {
                self.reconsume(LexState::Comment);
                None
            }
        }
    }

    fn comment_start_dash(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.go(LexState::CommentEnd);
                None
            }
            62 => {
                self.error(
                    "abrupt-closing-of-empty-comment",
                    "Empty comment abruptly closed by '->', use '-->'.",
                    At::Current,
                );
                self.go(LexState::Data);
                Some(self.emit_comment())
            }
            EOF => {
                self.eof_in_comment();
                self.reconsume(LexState::Data);
                Some(self.emit_comment())
            }
            _ => {
                self.temporary.push('-');
                self.reconsume(LexState::Comment);
                None
            }
        }
    }

    fn comment(&mut self, cp: i32) -> Option<Token> {
        match cp {
            60 => {
                self.temporary.push('<');
                self.go(LexState::CommentLt);
                None
            }
            45 => {
                self.go(LexState::CommentEndDash);
                None
            }
            0 => {
                self.unexpected_null();
                self.temporary.push('\u{FFFD}');
                None
            }
            EOF => {
                self.eof_in_comment();
                self.reconsume(LexState::Data);
                Some(self.emit_comment())
            }
            _ => {
                self.temporary.push(cp_char(cp));
                None
            }
        }
    }

    fn comment_lt(&mut self, cp: i32) -> Option<Token> {
        match cp {
            33 => {
                self.temporary.push('!');
                self.go(LexState::CommentLtBang);
                None
            }
            60 => {
                self.temporary.push('<');
                None
            }
            _ => {
                self.reconsume(LexState::Comment);
                None
            }
        }
    }

    fn comment_lt_bang(&mut self, cp: i32) -> Option<Token> {
        if cp == 45 {
            self.go(LexState::CommentLtBangDash);
        } else {
            self.go(LexState::Comment);
        }
        None
    }

    fn comment_lt_bang_dash(&mut self, cp: i32) -> Option<Token> {
        if cp == 45 {
            self.go(LexState::CommentLtBangDashDash);
        } else {
            self.go(LexState::CommentEndDash);
        }
        None
    }

    fn comment_lt_bang_dash_dash(&mut self, cp: i32) -> Option<Token> {
        if cp != 62 && cp != EOF {
            self.error("nested-comment", "Nested comment.", At::Current);
        }
        self.reconsume(LexState::CommentEnd);
        None
    }

    fn comment_end_dash(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.go(LexState::CommentEnd);
                None
            }
            EOF => {
                self.eof_in_comment();
                self.reconsume(LexState::Data);
                Some(self.emit_comment())
            }
            _ => {
                self.temporary.push('-');
                self.reconsume(LexState::Comment);
                None
            }
        }
    }

    fn comment_end(&mut self, cp: i32) -> Option<Token> {
        match cp {
            62 => {
                self.go(LexState::Data);
                Some(self.emit_comment())
            }
            33 => {
                self.go(LexState::CommentEndBang);
                None
            }
            45 => {
                self.temporary.push('-');
                None
            }
            EOF => {
                self.eof_in_comment();
                self.reconsume(LexState::Data);
                Some(self.emit_comment())
            }
            _ => {
                self.temporary.push_str("--");
                self.reconsume(LexState::Comment);
                None
            }
        }
    }

    fn comment_end_bang(&mut self, cp: i32) -> Option<Token> {
        match cp {
            45 => {
                self.temporary.push_str("--!");
                self.go(LexState::CommentEndDash);
                None
            }
            62 => {
                self.error(
                    "incorrectly-closed-comment",
                    "Comment closed incorrectly by '--!>', use '-->'.",
                    At::Current,
                );
                self.go(LexState::Data);
                Some(self.emit_comment())
            }
            EOF => {
                self.eof_in_comment();
                self.reconsume(LexState::Data);
                Some(self.emit_comment())
            }
            _ => {
                self.temporary.push_str("--!");
                self.reconsume(LexState::Comment);
                None
            }
        }
    }

    fn eof_in_comment(&mut self) {
        self.error("eof-in-comment", "End of input in comment.", At::Current);
    }

    fn doctype(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            self.go(LexState::BeforeDoctypeName);
            return None;
        }
        match cp {
            62 => {
                self.reconsume(LexState::BeforeDoctypeName);
                None
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "missing-whitespace-before-doctype-name",
                    "Missing whitespace between 'DOCTYPE' keyword and DOCTYPE name.",
                    At::Current,
                );
                self.reconsume(LexState::BeforeDoctypeName);
                None
            }
        }
    }

    fn before_doctype_name(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        match cp {
            0 => {
                self.unexpected_null();
                self.reset_doctype_name(REPLACEMENT);
                self.go(LexState::DoctypeName);
                None
            }
            62 => {
                self.error("missing-doctype-name", "Missing DOCTYPE name.", At::Current);
                self.force_quirks();
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                let lowered = self.lower(cp);
                self.reset_doctype_name(lowered);
                self.go(LexState::DoctypeName);
                None
            }
        }
    }

    fn reset_doctype_name(&mut self, cp: i32) {
        self.doctype_name.clear();
        self.doctype_name.push(cp_char(cp));
        self.doctype_public_id.clear();
        self.doctype_system_id.clear();
        self.doctype_has_public_id = false;
        self.doctype_has_system_id = false;
        self.doctype_force_quirks = false;
    }

    fn doctype_name(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            self.go(LexState::AfterDoctypeName);
            return None;
        }
        match cp {
            62 => {
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            0 => {
                self.unexpected_null();
                self.doctype_name.push('\u{FFFD}');
                None
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                let lowered = self.lower(cp);
                self.doctype_name.push(cp_char(lowered));
                None
            }
        }
    }

    fn after_doctype_name(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        let upcoming = self.slice(self.index, self.index.saturating_add(6));
        if starts_with_ascii_ci(&upcoming, "public") {
            self.index += 6;
            self.reconsume(LexState::AfterDoctypePublic);
            return None;
        }
        if starts_with_ascii_ci(&upcoming, "system") {
            self.index += 6;
            self.reconsume(LexState::AfterDoctypeSystem);
            return None;
        }
        if cp == 62 {
            self.go(LexState::Data);
            return Some(self.emit_doctype());
        }
        if cp == EOF {
            self.eof_in_doctype();
            self.force_quirks();
            self.reconsume(LexState::Data);
            return Some(self.emit_doctype());
        }
        self.error(
            "invalid-character-sequence-after-doctype-name",
            "Invalid character sequence after DOCTYPE name, expected 'PUBLIC', 'SYSTEM', or '>'.",
            At::Current,
        );
        self.force_quirks();
        self.reconsume(LexState::BogusDoctype);
        None
    }

    fn after_doctype_public(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            self.go(LexState::BeforeDoctypePublic);
            return None;
        }
        match cp {
            34 => {
                self.error(
                    "missing-whitespace-after-doctype-public-keyword",
                    "Missing whitespace after 'PUBLIC' keyword.",
                    At::Current,
                );
                self.temporary.clear();
                self.doctype_has_public_id = true;
                self.go(LexState::DoctypePublicDouble);
                None
            }
            39 => {
                self.error(
                    "missing-whitespace-after-doctype-public-keyword",
                    "Missing whitespace after 'PUBLIC' keyword.",
                    At::Current,
                );
                self.temporary.clear();
                self.doctype_has_public_id = true;
                self.go(LexState::DoctypePublicSingle);
                None
            }
            62 => {
                self.error(
                    "missing-doctype-public-identifier",
                    "Missing DOCTYPE public identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "missing-quote-before-doctype-public-identifier",
                    "Missing quote before DOCTYPE public identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.reconsume(LexState::BogusDoctype);
                None
            }
        }
    }

    fn before_doctype_public(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        match cp {
            34 => {
                self.temporary.clear();
                self.doctype_has_public_id = true;
                self.go(LexState::DoctypePublicDouble);
                None
            }
            39 => {
                self.temporary.clear();
                self.doctype_has_public_id = true;
                self.go(LexState::DoctypePublicSingle);
                None
            }
            62 => {
                self.error(
                    "missing-doctype-public-identifier",
                    "Missing DOCTYPE public identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "missing-quote-before-doctype-public-identifier",
                    "Missing quote before DOCTYPE public identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.reconsume(LexState::BogusDoctype);
                None
            }
        }
    }

    fn doctype_public_double(&mut self, cp: i32) -> Option<Token> {
        self.doctype_quoted(
            cp,
            34,
            true,
            "quotation mark (\")",
            "abrupt-doctype-public-identifier",
            "DOCTYPE public identifier missing closing %s.",
        )
    }

    fn doctype_public_single(&mut self, cp: i32) -> Option<Token> {
        self.doctype_quoted(
            cp,
            39,
            true,
            "apostrophe (')",
            "abrupt-doctype-public-identifier",
            "DOCTYPE public identifier missing closing %s.",
        )
    }

    fn doctype_quoted(
        &mut self,
        cp: i32,
        quote: i32,
        public_id: bool,
        closer: &str,
        code: &str,
        template: &str,
    ) -> Option<Token> {
        if cp == quote {
            self.store_doctype_id(public_id);
            self.go(if public_id {
                LexState::AfterDoctypePublicId
            } else {
                LexState::AfterDoctypeSystemId
            });
            return None;
        }
        if cp == 0 {
            self.unexpected_null();
            self.temporary.push('\u{FFFD}');
            return None;
        }
        if cp == 62 {
            self.error(code, template.replacen("%s", closer, 1), At::Current);
            self.force_quirks();
            self.store_doctype_id(public_id);
            self.go(LexState::Data);
            return Some(self.emit_doctype());
        }
        if cp == EOF {
            self.eof_in_doctype();
            self.force_quirks();
            self.reconsume(LexState::Data);
            return Some(self.emit_doctype());
        }
        self.temporary.push(cp_char(cp));
        None
    }

    fn store_doctype_id(&mut self, public_id: bool) {
        if public_id {
            self.doctype_public_id.clone_from(&self.temporary);
        } else {
            self.doctype_system_id.clone_from(&self.temporary);
        }
    }

    fn after_doctype_public_id(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            self.go(LexState::BetweenDoctypeIds);
            return None;
        }
        match cp {
            62 => {
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            34 => {
                self.error(
                    "missing-whitespace-between-doctype-public-and-system-identifiers",
                    "Missing whitespace between DOCTYPE public and system identifiers.",
                    At::Current,
                );
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemDouble);
                None
            }
            39 => {
                self.error(
                    "missing-whitespace-between-doctype-public-and-system-identifiers",
                    "Missing whitespace between DOCTYPE public and system identifiers.",
                    At::Current,
                );
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemSingle);
                None
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "missing-quote-before-doctype-system-identifier",
                    "Missing quote before DOCTYPE system identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.reconsume(LexState::BogusDoctype);
                None
            }
        }
    }

    fn between_doctype_ids(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        match cp {
            62 => {
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            34 => {
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemDouble);
                None
            }
            39 => {
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemSingle);
                None
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "missing-quote-before-doctype-system-identifier",
                    "Missing quote before DOCTYPE system identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.reconsume(LexState::BogusDoctype);
                None
            }
        }
    }

    fn after_doctype_system(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            self.go(LexState::BeforeDoctypeSystem);
            return None;
        }
        match cp {
            34 => {
                self.error(
                    "missing-whitespace-after-doctype-system-keyword",
                    "Missing whitespace after 'SYSTEM' keyword.",
                    At::Current,
                );
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemDouble);
                None
            }
            39 => {
                self.error(
                    "missing-whitespace-after-doctype-system-keyword",
                    "Missing whitespace after 'SYSTEM' keyword.",
                    At::Current,
                );
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemSingle);
                None
            }
            62 => {
                self.error(
                    "missing-doctype-system-identifier",
                    "Missing DOCTYPE system identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "missing-quote-before-doctype-system-identifier",
                    "Missing quote before DOCTYPE system identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.reconsume(LexState::BogusDoctype);
                None
            }
        }
    }

    fn before_doctype_system(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        match cp {
            34 => {
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemDouble);
                None
            }
            39 => {
                self.temporary.clear();
                self.doctype_has_system_id = true;
                self.go(LexState::DoctypeSystemSingle);
                None
            }
            62 => {
                self.error(
                    "missing-doctype-system-identifier",
                    "Missing DOCTYPE system identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "missing-quote-before-doctype-system-identifier",
                    "Missing quote before DOCTYPE system identifier.",
                    At::Current,
                );
                self.force_quirks();
                self.reconsume(LexState::BogusDoctype);
                None
            }
        }
    }

    fn doctype_system_double(&mut self, cp: i32) -> Option<Token> {
        self.doctype_quoted(
            cp,
            34,
            false,
            "quotation mark (\")",
            "abrupt-doctype-system-identifier",
            "DOCTYPE system identifier missing closing %s.",
        )
    }

    fn doctype_system_single(&mut self, cp: i32) -> Option<Token> {
        self.doctype_quoted(
            cp,
            39,
            false,
            "apostrophe (')",
            "abrupt-doctype-system-identifier",
            "DOCTYPE system identifier missing closing %s.",
        )
    }

    fn after_doctype_system_id(&mut self, cp: i32) -> Option<Token> {
        if self.space(cp) {
            return None;
        }
        match cp {
            62 => {
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            EOF => {
                self.eof_in_doctype();
                self.force_quirks();
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => {
                self.error(
                    "unexpected-character-after-doctype-system-identifier",
                    "Unexpected character after DOCTYPE system identifier.",
                    At::Current,
                );
                self.reconsume(LexState::BogusDoctype);
                None
            }
        }
    }

    fn bogus_doctype(&mut self, cp: i32) -> Option<Token> {
        match cp {
            62 => {
                self.go(LexState::Data);
                Some(self.emit_doctype())
            }
            0 => {
                self.unexpected_null();
                None
            }
            EOF => {
                self.reconsume(LexState::Data);
                Some(self.emit_doctype())
            }
            _ => None,
        }
    }

    fn force_quirks(&mut self) {
        self.doctype_force_quirks = true;
    }

    fn eof_in_doctype(&mut self) {
        self.error("eof-in-doctype", "End of input in DOCTYPE.", At::Current);
    }

    fn emit_doctype(&mut self) -> Token {
        let (line, column, byte_offset) = self.start_pos();
        let mut token = Token::blank(TokenKind::Doctype);
        token.name = std::mem::take(&mut self.doctype_name);
        token.public_id = std::mem::take(&mut self.doctype_public_id);
        token.system_id = std::mem::take(&mut self.doctype_system_id);
        token.has_public_id = self.doctype_has_public_id;
        token.has_system_id = self.doctype_has_system_id;
        token.force_quirks = self.doctype_force_quirks;
        token.line = line;
        token.column = column;
        token.byte_offset = byte_offset;
        self.doctype_has_public_id = false;
        self.doctype_has_system_id = false;
        self.doctype_force_quirks = false;
        self.finish_token();
        token
    }

    fn cdata(&mut self, cp: i32) -> Option<Token> {
        match cp {
            93 => {
                self.mark();
                self.go(LexState::CdataBracket);
                None
            }
            0 => {
                self.unexpected_null();
                Some(self.emit_cdata(REPLACEMENT))
            }
            EOF => {
                self.error(
                    "eof-in-cdata",
                    "End of input in CDATA section.",
                    At::Current,
                );
                self.in_cdata = false;
                self.reconsume(LexState::Data);
                Some(self.emit_eof())
            }
            _ => Some(self.emit_cdata(cp)),
        }
    }

    fn cdata_bracket(&mut self, cp: i32) -> Option<Token> {
        if cp == 93 {
            self.go(LexState::CdataEnd);
            None
        } else {
            self.reconsume(LexState::Cdata);
            Some(self.emit_from_mark())
        }
    }

    fn cdata_end(&mut self, cp: i32) -> Option<Token> {
        match cp {
            93 => {
                let token = self.emit_from_mark();
                self.resume = None;
                self.mark();
                self.go(LexState::Cdata);
                Some(token)
            }
            62 => {
                self.in_cdata = false;
                self.go(LexState::Data);
                None
            }
            _ => {
                self.reconsume(LexState::Cdata);
                Some(self.emit_from_mark())
            }
        }
    }

    fn character_reference(&mut self, cp: i32) -> Option<Token> {
        if self.alnum(cp) {
            self.reconsume(LexState::NamedReference);
            return None;
        }
        if cp == 35 {
            self.go(LexState::NumericReference);
            return None;
        }
        let back = self.return_state;
        self.reconsume(back);
        self.flush_reference_text()
    }

    fn named_reference(&mut self, _cp: i32) -> Option<Token> {
        // The longest name in entities.rs is 32 characters.
        let end = self.index.saturating_add(32).min(self.chars.len());
        let suffix = self.slice(self.index, end);
        if let Some((length, first, second)) = match_named(&suffix) {
            let end = self.index + length;
            let semicolon = length > 0 && self.chars.get(end - 1).is_some_and(|ch| ch.cp == 59);
            self.index = end;
            let nxt = self.current_cp();
            if self.attribute_reference() && !semicolon && (nxt == 61 || self.alnum(nxt)) {
                let back = self.return_state;
                self.reconsume(back);
                return self.flush_reference_text();
            }
            if !semicolon {
                let shown = self.slice(self.mark, self.index);
                self.error(
                    "missing-semicolon-after-character-reference",
                    format!("Missing semicolon after character reference '{shown}'."),
                    At::Mark,
                );
            }
            let back = self.return_state;
            self.reconsume(back);
            return self.flush_codepoint(first, second);
        }
        self.reconsume(LexState::AmbiguousAmpersand);
        self.flush_reference_text()
    }

    fn ambiguous_ampersand(&mut self, cp: i32) -> Option<Token> {
        if self.alnum(cp) {
            return self.append_or_emit(cp);
        }
        if cp == 59 {
            let shown = self.slice(self.mark, self.index + 1);
            self.error(
                "unknown-named-character-reference",
                format!("Unknown named character reference '{shown}'."),
                At::Mark,
            );
        }
        let back = self.return_state;
        self.reconsume(back);
        None
    }

    fn numeric_reference(&mut self, cp: i32) -> Option<Token> {
        self.ref_value = 0;
        if cp == 120 || cp == 88 {
            self.go(LexState::HexStart);
        } else {
            self.reconsume(LexState::DecStart);
        }
        None
    }

    fn hex_start(&mut self, cp: i32) -> Option<Token> {
        if self.hex(cp) {
            self.reconsume(LexState::HexRef);
            None
        } else {
            let shown = self.slice(self.mark, self.index);
            self.error(
                "absence-of-digits-in-numeric-character-reference",
                format!("Numeric character reference '{shown}' does not contain any hexadecimal digits."),
                At::Mark,
            );
            let back = self.return_state;
            self.reconsume(back);
            self.flush_reference_text()
        }
    }

    fn dec_start(&mut self, cp: i32) -> Option<Token> {
        if self.digit(cp) {
            self.reconsume(LexState::DecRef);
            None
        } else {
            let shown = self.slice(self.mark, self.index);
            self.error(
                "absence-of-digits-in-numeric-character-reference",
                format!("Numeric character reference '{shown}' does not contain any digits."),
                At::Mark,
            );
            let back = self.return_state;
            self.reconsume(back);
            self.flush_reference_text()
        }
    }

    fn hex_ref(&mut self, cp: i32) -> Option<Token> {
        if self.digit(cp) {
            self.bump_ref(16, (cp - 48) as u32);
        } else if (65..=70).contains(&cp) {
            self.bump_ref(16, (cp - 55) as u32);
        } else if (97..=102).contains(&cp) {
            self.bump_ref(16, (cp - 87) as u32);
        } else if cp == 59 {
            self.go(LexState::NumericEnd);
        } else {
            self.missing_semicolon();
            self.reconsume(LexState::NumericEnd);
        }
        None
    }

    fn dec_ref(&mut self, cp: i32) -> Option<Token> {
        if self.digit(cp) {
            self.bump_ref(10, (cp - 48) as u32);
        } else if cp == 59 {
            self.go(LexState::NumericEnd);
        } else {
            self.missing_semicolon();
            self.reconsume(LexState::NumericEnd);
        }
        None
    }

    fn bump_ref(&mut self, base: u32, digit: u32) {
        let next = self.ref_value.saturating_mul(base).saturating_add(digit);
        self.ref_value = if next > MAX_CHAR { MAX_CHAR + 1 } else { next };
    }

    fn hex(&self, cp: i32) -> bool {
        self.digit(cp) || (65..=70).contains(&cp) || (97..=102).contains(&cp)
    }

    fn missing_semicolon(&mut self) {
        let shown = self.slice(self.mark, self.index);
        self.error(
            "missing-semicolon-after-character-reference",
            format!("Missing semicolon after character reference '{shown}'."),
            At::Mark,
        );
    }

    fn numeric_end(&mut self, _cp: i32) -> Option<Token> {
        let value = self.normalize_numeric(self.ref_value);
        let back = self.return_state;
        self.reconsume(back);
        self.flush_codepoint(value, None)
    }

    fn normalize_numeric(&mut self, value: u32) -> u32 {
        let shown = self.slice(self.mark, self.index);
        if value == 0 {
            self.error(
                "null-character-reference",
                format!("Numeric character reference '{shown}' references U+0000."),
                At::Mark,
            );
            return REPLACEMENT as u32;
        }
        if value > MAX_CHAR {
            self.error(
                "character-reference-outside-unicode-range",
                format!("Numeric character reference '{shown}' references a code point that is outside the valid Unicode range."),
                At::Mark,
            );
            return REPLACEMENT as u32;
        }
        if (0xD800..=0xDFFF).contains(&value) {
            self.error(
                "surrogate-character-reference",
                format!("Numeric character reference '{shown}' references surrogate U+{value:4X}."),
                At::Mark,
            );
            return REPLACEMENT as u32;
        }
        let as_cp = value as i32;
        if (0xFDD0..=0xFDEF).contains(&value) || (value & 0xFFFE) == 0xFFFE {
            self.error(
                "noncharacter-character-reference",
                format!(
                    "Numeric character reference '{shown}' references noncharacter U+{value:04X}."
                ),
                At::Mark,
            );
        } else if self.c1_control(as_cp)
            || value == 0x0D
            || (self.control(as_cp) && !self.space(as_cp))
        {
            self.error(
                "control-character-reference",
                format!("Numeric character reference '{shown}' references prohibited control code point U+{value:04X}."),
                At::Mark,
            );
            return windows1252(value);
        }
        value
    }

    fn attribute_reference(&self) -> bool {
        matches!(
            self.return_state,
            LexState::AttrDouble | LexState::AttrSingle | LexState::AttrUnquoted
        )
    }

    fn flush_reference_text(&mut self) -> Option<Token> {
        if self.attribute_reference() {
            let text = self.slice(self.mark, self.index);
            self.buffer.push_str(&text);
            None
        } else {
            Some(self.emit_from_mark())
        }
    }

    fn flush_codepoint(&mut self, first: u32, second: Option<u32>) -> Option<Token> {
        if self.attribute_reference() {
            self.buffer.push(cp_char(first as i32));
            if let Some(second) = second {
                self.buffer.push(cp_char(second as i32));
            }
            None
        } else {
            self.buffered = second.map(|cp| cp as i32);
            Some(self.emit_char(first as i32))
        }
    }

    fn append_or_emit(&mut self, cp: i32) -> Option<Token> {
        if self.attribute_reference() {
            self.buffer.push(cp_char(cp));
            None
        } else {
            Some(self.emit_char(cp))
        }
    }
}
