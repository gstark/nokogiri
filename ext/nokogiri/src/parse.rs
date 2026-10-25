//! XML and HTML parsers that fill a [`Store`](crate::store::Store).

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use crate::store::{
    ContentNode, DeclData, Notation, Store, ATTRIBUTE, ATTRIBUTE_DECL, CDATA, COMMENT, DTD, ELEMENT,
    ELEMENT_DECL, ENTITY_DECL, ENTITY_REF, PI, TEXT, copy_subtree,
};

pub const RECOVER: i32 = 1 << 0;
pub const NOENT: i32 = 1 << 1;
pub const DTDLOAD: i32 = 1 << 2;
pub const DTDVALID: i32 = 1 << 4;
pub const NOBLANKS: i32 = 1 << 8;
pub const NOCDATA: i32 = 1 << 14;

const CONTENT_PCDATA: i32 = 1;
const CONTENT_ELEMENT: i32 = 2;
const CONTENT_SEQ: i32 = 3;
const CONTENT_OR: i32 = 4;
const OCCUR_ONCE: i32 = 1;
const OCCUR_OPT: i32 = 2;
const OCCUR_MULT: i32 = 3;
const OCCUR_PLUS: i32 = 4;
const ELEM_EMPTY: i32 = 1;
const ELEM_ANY: i32 = 2;
const ELEM_MIXED: i32 = 3;
const ELEM_CHILDREN: i32 = 4;

#[derive(Clone, Debug)]
pub struct ParseError {
    pub message: String,
    pub line: i64,
    pub column: i64,
    pub level: i32,
    pub domain: i32,
    pub code: i32,
}

pub struct Parsed {
    pub store: Rc<RefCell<Store>>,
    pub errors: Vec<ParseError>,
}

pub struct FragmentResult {
    pub ids: Vec<u32>,
    pub errors: Vec<ParseError>,
}

struct Cur<'a> {
    input: &'a str,
    bytes: &'a [u8],
    i: usize,
    line: i64,
    col: i64,
}

impl<'a> Cur<'a> {
    fn new(input: &'a str) -> Self {
        Self { input, bytes: input.as_bytes(), i: 0, line: 1, col: 1 }
    }

    fn eof(&self) -> bool {
        self.i >= self.bytes.len()
    }

    fn rest(&self) -> &'a str {
        &self.input[self.i..]
    }

    fn peek(&self) -> Option<char> {
        self.rest().chars().next()
    }

    fn starts_with(&self, s: &str) -> bool {
        self.rest().starts_with(s)
    }

    fn bump(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.i += ch.len_utf8();
        if ch == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(ch)
    }

    fn bump_n(&mut self, n: usize) {
        for _ in 0..n {
            if self.bump().is_none() {
                break;
            }
        }
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(c) if c.is_whitespace()) {
            self.bump();
        }
    }
}

fn is_name_start(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_' || c == ':' || (!c.is_ascii() && !c.is_whitespace())
}

fn is_name_char(c: char) -> bool {
    is_name_start(c) || c.is_ascii_digit() || c == '-' || c == '.'
}

fn decode_numeric(body: &str) -> Option<char> {
    let (digits, radix) = if let Some(hex) = body.strip_prefix('#') {
        let hex = hex.strip_prefix('x').or_else(|| hex.strip_prefix('X'))?;
        (hex, 16)
    } else {
        return None;
    };
    let code = u32::from_str_radix(digits, radix).ok()?;
    char::from_u32(code).filter(|c| *c != '\0')
}

fn decode_decimal(body: &str) -> Option<char> {
    let digits = body.strip_prefix('#')?;
    if digits.starts_with('x') || digits.starts_with('X') {
        return None;
    }
    let code = digits.parse::<u32>().ok()?;
    char::from_u32(code).filter(|c| *c != '\0')
}

fn html_entity(name: &str) -> Option<char> {
    Some(match name {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => '\u{00A0}',
        "copy" => '\u{00A9}',
        "reg" => '\u{00AE}',
        "trade" => '\u{2122}',
        "mdash" => '\u{2014}',
        "ndash" => '\u{2013}',
        "hellip" => '\u{2026}',
        "lsquo" => '\u{2018}',
        "rsquo" => '\u{2019}',
        "ldquo" => '\u{201C}',
        "rdquo" => '\u{201D}',
        "bull" => '\u{2022}',
        "middot" => '\u{00B7}',
        "times" => '\u{00D7}',
        "divide" => '\u{00F7}',
        "laquo" => '\u{00AB}',
        "raquo" => '\u{00BB}',
        "euro" => '\u{20AC}',
        "pound" => '\u{00A3}',
        "yen" => '\u{00A5}',
        "cent" => '\u{00A2}',
        "sect" => '\u{00A7}',
        "deg" => '\u{00B0}',
        "plusmn" => '\u{00B1}',
        "para" => '\u{00B6}',
        "micro" => '\u{00B5}',
        "shy" => '\u{00AD}',
        "ensp" => '\u{2002}',
        "emsp" => '\u{2003}',
        "thinsp" => '\u{2009}',
        _ => return None,
    })
}

fn xml_predefined(name: &str) -> Option<char> {
    Some(match name {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        _ => return None,
    })
}

#[derive(Clone)]
struct EntityRec {
    name: String,
    literal: Option<String>,
    system_id: Option<String>,
    expand: bool,
}

struct Builder {
    store: Rc<RefCell<Store>>,
    errors: Vec<ParseError>,
    entities: Vec<EntityRec>,
    /// Directory of the loaded external subset. Relative entity system ids use this directory.
    entity_base: Option<String>,
    html: bool,
    options: i32,
}

impl Builder {
    fn new(html: bool, options: i32, key: u64) -> Self {
        let store = Store::new_document(html, key);
        if html {
            let mut store_ref = store.borrow_mut();
            store_ref.nodes[0].version.clear();
            store_ref.nodes[0].encoding = Some("UTF-8".to_string());
        }
        Self { store, errors: Vec::new(), entities: Vec::new(), entity_base: None, html, options }
    }

    fn error(&mut self, message: impl Into<String>, line: i64, column: i64, level: i32) {
        self.errors.push(ParseError {
            message: message.into(),
            line,
            column,
            level,
            domain: 1,
            code: if level >= 3 { 77 } else { 1 },
        });
    }

    fn noblanks(&self) -> bool {
        self.options & NOBLANKS != 0
    }

    fn add(&mut self, kind: i32, owner: u32) -> u32 {
        self.store.borrow_mut().alloc(kind, owner)
    }

    fn set_name(&mut self, id: u32, name: impl Into<String>) {
        self.store.borrow_mut().nodes[id as usize].name = Some(name.into());
    }

    fn set_content(&mut self, id: u32, content: impl Into<String>) {
        self.store.borrow_mut().nodes[id as usize].content = content.into();
    }

    fn set_line(&mut self, id: u32, line: i64, column: i64) {
        let node = &mut self.store.borrow_mut().nodes[id as usize];
        node.line = line;
        node.column = column;
    }

    fn append(&mut self, parent: u32, child: u32) {
        self.store.borrow_mut().append_child(parent, child);
    }

    fn add_text(&mut self, parent: u32, text: &str, line: i64, column: i64) {
        if text.is_empty() {
            return;
        }
        let (parent_kind, last) = {
            let store = self.store.borrow();
            let parent_node = &store.nodes[parent as usize];
            (parent_node.kind, parent_node.children.last().copied())
        };
        let doc_level = parent_kind == crate::store::DOCUMENT || parent_kind == crate::store::HTML_DOCUMENT;
        let blank = text.chars().all(char::is_whitespace);
        // libxml does not keep character data as a direct child of an XML document.
        if doc_level && !self.html {
            return;
        }
        if blank && self.noblanks() {
            return;
        }
        if let Some(last) = last {
            let last_is_text = self.store.borrow().nodes[last as usize].kind == TEXT;
            if last_is_text {
                self.store.borrow_mut().nodes[last as usize].content.push_str(text);
                return;
            }
        }
        let id = self.add(TEXT, 0);
        self.set_name(id, "text");
        self.set_content(id, text);
        self.set_line(id, line, column);
        self.append(parent, id);
    }

    fn define_ns(&mut self, element: u32, prefix: Option<String>, href: String) -> u32 {
        let id = self.store.borrow_mut().add_ns(prefix, href);
        self.store.borrow_mut().nodes[element as usize].ns_defs.push(id);
        id
    }

    fn bind_element_ns(&mut self, element: u32) {
        let (name, explicit) = {
            let store = self.store.borrow();
            let node = &store.nodes[element as usize];
            (node.name.clone().unwrap_or_default(), node.ns)
        };
        if explicit.is_some() {
            return;
        }
        let (prefix, local) = match split_qname(&name) {
            Some((prefix, local)) => (Some(prefix), local),
            None => (None, name.clone()),
        };
        if prefix.is_some() {
            self.store.borrow_mut().nodes[element as usize].name = Some(local);
        }
        let found = self.store.borrow().lookup_ns(element, prefix.as_deref());
        if let Some(ns) = found {
            self.store.borrow_mut().nodes[element as usize].ns = Some(ns);
        } else if let Some(prefix) = prefix {
            if prefix == "xml" {
                let ns = self.store.borrow_mut().ensure_xml_ns();
                self.store.borrow_mut().nodes[element as usize].ns = Some(ns);
            }
        }
    }

    fn bind_attr_ns(&mut self, element: u32, attr: u32) {
        let name = self.store.borrow().nodes[attr as usize].name.clone().unwrap_or_default();
        let Some((prefix, local)) = split_qname(&name) else {
            return;
        };
        self.store.borrow_mut().nodes[attr as usize].name = Some(local);
        if prefix == "xml" {
            let ns = self.store.borrow_mut().ensure_xml_ns();
            self.store.borrow_mut().nodes[attr as usize].ns = Some(ns);
            return;
        }
        if prefix == "xmlns" {
            return;
        }
        let found = self.store.borrow().lookup_ns(element, Some(prefix.as_str()));
        if let Some(ns) = found {
            self.store.borrow_mut().nodes[attr as usize].ns = Some(ns);
        }
    }
}

fn split_qname(name: &str) -> Option<(String, String)> {
    let (prefix, local) = name.split_once(':')?;
    if prefix.is_empty() || local.is_empty() {
        return None;
    }
    Some((prefix.to_string(), local.to_string()))
}

pub fn parse_xml(input: &str, url: Option<String>, encoding: Option<String>, options: i32, key: u64) -> Parsed {
    parse_document(input, url, encoding, options, key, false)
}

pub fn parse_html(input: &str, url: Option<String>, encoding: Option<String>, options: i32, key: u64) -> Parsed {
    parse_document(input, url, encoding, options, key, true)
}

fn parse_document(
    input: &str,
    url: Option<String>,
    encoding: Option<String>,
    options: i32,
    key: u64,
    html: bool,
) -> Parsed {
    let mut builder = Builder::new(html, options, key);
    if let Some(url) = url {
        builder.store.borrow_mut().nodes[0].url = Some(url);
    }
    if let Some(encoding) = encoding {
        if !encoding.is_empty() {
            builder.store.borrow_mut().nodes[0].encoding = Some(encoding);
        }
    }
    if html {
        parse_html_tree(&mut builder, input);
    } else {
        parse_xml_tree(&mut builder, input);
        if options & DTDVALID != 0 {
            validate_document(&mut builder);
        }
    }
    Parsed { store: builder.store, errors: builder.errors }
}

fn parse_xml_tree(builder: &mut Builder, input: &str) {
    let mut cur = Cur::new(input);
    if cur.starts_with("\u{feff}") {
        cur.bump();
    }
    parse_xml_decl(builder, &mut cur);
    let mut saw_root = false;
    let mut open: Vec<(u32, String, i64)> = Vec::new();
    while !cur.eof() {
        if cur.starts_with("<?") {
            parse_pi(builder, &mut cur, current_parent(&open));
            continue;
        }
        if cur.starts_with("<!--") {
            parse_comment(builder, &mut cur, current_parent(&open));
            continue;
        }
        if cur.starts_with("<![CDATA[") {
            parse_cdata(builder, &mut cur, current_parent(&open));
            continue;
        }
        if cur.starts_with("<!DOCTYPE") || cur.starts_with("<!doctype") {
            parse_doctype(builder, &mut cur, false);
            continue;
        }
        if cur.starts_with("</") {
            close_tag(builder, &mut cur, &mut open, false);
            continue;
        }
        if cur.starts_with("<") {
            if saw_root && open.is_empty() {
                builder.error("Extra content at the end of the document", cur.line, cur.col, 3);
            }
            if let Some(id) = parse_start_tag(builder, &mut cur, current_parent(&open), false) {
                let name = builder.store.borrow().nodes[id as usize].name.clone().unwrap_or_default();
                let empty = builder.store.borrow().nodes[id as usize].children.is_empty()
                    && builder.store.borrow().nodes[id as usize].content == "\u{0}empty";
                if builder.store.borrow().nodes[id as usize].content == "\u{0}empty" {
                    builder.store.borrow_mut().nodes[id as usize].content.clear();
                }
                if open.is_empty() {
                    saw_root = true;
                }
                if !empty {
                    open.push((id, name, cur.line));
                }
            }
            continue;
        }
        let start_line = cur.line;
        let start_col = cur.col;
        let mut text = String::new();
        while let Some(ch) = cur.peek() {
            if ch == '<' {
                break;
            }
            if ch == '&' {
                if !text.is_empty() {
                    builder.add_text(current_parent(&open), &text, start_line, start_col);
                    text.clear();
                }
                parse_reference(builder, &mut cur, current_parent(&open), false);
                continue;
            }
            text.push(ch);
            cur.bump();
        }
        if !text.is_empty() {
            builder.add_text(current_parent(&open), &text, start_line, start_col);
        }
    }
    if let Some((_, name, line)) = open.first() {
        builder.error(
            format!("Premature end of data in tag {name} line {line}"),
            cur.line,
            cur.col,
            3,
        );
    } else if !saw_root {
        builder.error("Start tag expected, '<' not found", cur.line, cur.col, 3);
    }
}

fn current_parent(open: &[(u32, String, i64)]) -> u32 {
    open.last().map(|(id, _, _)| *id).unwrap_or(0)
}

fn parse_xml_decl(builder: &mut Builder, cur: &mut Cur<'_>) {
    if !cur.starts_with("<?xml") {
        return;
    }
    let line = cur.line;
    let col = cur.col;
    cur.bump_n(5);
    let header = read_until(cur, "?>");
    if let Some(version) = attr_value(&header, "version") {
        builder.store.borrow_mut().nodes[0].version = version;
    }
    if let Some(encoding) = attr_value(&header, "encoding") {
        builder.store.borrow_mut().nodes[0].encoding = Some(encoding);
    }
    let _ = (line, col);
}

fn attr_value(header: &str, name: &str) -> Option<String> {
    let index = header.find(name)?;
    let rest = header[index + name.len()..].trim_start();
    let rest = rest.strip_prefix('=')?.trim_start();
    let quote = rest.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let rest = &rest[quote.len_utf8()..];
    let end = rest.find(quote)?;
    Some(rest[..end].to_string())
}

fn read_until(cur: &mut Cur<'_>, marker: &str) -> String {
    let start = cur.i;
    if let Some(rel) = cur.rest().find(marker) {
        let text = cur.input[start..cur.i + rel].to_string();
        cur.bump_n(cur.input[start..cur.i + rel].chars().count() + marker.chars().count());
        text
    } else {
        let text = cur.rest().to_string();
        cur.i = cur.bytes.len();
        text
    }
}

fn parse_pi(builder: &mut Builder, cur: &mut Cur<'_>, parent: u32) {
    let line = cur.line;
    let col = cur.col;
    cur.bump_n(2);
    let mut target = String::new();
    while let Some(ch) = cur.peek() {
        if ch.is_whitespace() || ch == '?' {
            break;
        }
        target.push(ch);
        cur.bump();
    }
    cur.skip_ws();
    let body = if let Some(rel) = cur.rest().find("?>") {
        let body = cur.rest()[..rel].to_string();
        cur.bump_n(cur.rest()[..rel].chars().count() + 2);
        body
    } else {
        let body = cur.rest().to_string();
        cur.i = cur.bytes.len();
        body
    };
    if target.eq_ignore_ascii_case("xml") {
        builder.error("XML declaration allowed only at the start of the document", line, col, 3);
    }
    let id = builder.add(PI, 0);
    builder.set_name(id, target);
    builder.set_content(id, body.trim_end().to_string());
    builder.set_line(id, line, col);
    builder.append(parent, id);
}

fn parse_comment(builder: &mut Builder, cur: &mut Cur<'_>, parent: u32) {
    let line = cur.line;
    let col = cur.col;
    cur.bump_n(4);
    let body = if let Some(rel) = cur.rest().find("-->") {
        let body = cur.rest()[..rel].to_string();
        cur.bump_n(cur.rest()[..rel].chars().count() + 3);
        body
    } else {
        builder.error("Comment not terminated", line, col, 3);
        let body = cur.rest().to_string();
        cur.i = cur.bytes.len();
        body
    };
    let id = builder.add(COMMENT, 0);
    builder.set_name(id, "comment");
    builder.set_content(id, body);
    builder.set_line(id, line, col);
    builder.append(parent, id);
}

fn parse_cdata(builder: &mut Builder, cur: &mut Cur<'_>, parent: u32) {
    let line = cur.line;
    let col = cur.col;
    cur.bump_n(9);
    let body = if let Some(rel) = cur.rest().find("]]>") {
        let body = cur.rest()[..rel].to_string();
        cur.bump_n(cur.rest()[..rel].chars().count() + 3);
        body
    } else {
        builder.error("CData section not finished", line, col, 3);
        let body = cur.rest().to_string();
        cur.i = cur.bytes.len();
        body
    };
    if builder.options & NOCDATA != 0 {
        builder.add_text(parent, &body, line, col);
        return;
    }
    let id = builder.add(CDATA, 0);
    builder.set_content(id, body);
    builder.set_line(id, line, col);
    builder.append(parent, id);
}

fn parse_doctype(builder: &mut Builder, cur: &mut Cur<'_>, html: bool) {
    let line = cur.line;
    let col = cur.col;
    cur.bump_n(9);
    cur.skip_ws();
    let mut name = String::new();
    while let Some(ch) = cur.peek() {
        if ch.is_whitespace() || ch == '>' || ch == '[' {
            break;
        }
        name.push(ch);
        cur.bump();
    }
    cur.skip_ws();
    let mut external_id = None;
    let mut system_id = None;
    let keyword = read_keyword(cur);
    if keyword.eq_ignore_ascii_case("PUBLIC") {
        cur.skip_ws();
        external_id = read_quoted(cur);
        cur.skip_ws();
        system_id = read_quoted(cur);
    } else if keyword.eq_ignore_ascii_case("SYSTEM") {
        cur.skip_ws();
        system_id = read_quoted(cur);
    }
    cur.skip_ws();
    let mut inner = None;
    if cur.peek() == Some('[') {
        cur.bump();
        let mut depth = 1;
        let mut text = String::new();
        while let Some(ch) = cur.bump() {
            if ch == '[' {
                depth += 1;
            } else if ch == ']' {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            text.push(ch);
        }
        inner = Some(text);
    }
    while let Some(ch) = cur.peek() {
        if ch == '>' {
            cur.bump();
            break;
        }
        cur.bump();
    }
    if html {
        name = name.to_ascii_lowercase();
    }
    let dtd_name = if name.is_empty() { "html".to_string() } else { name };
    let id = builder.add(DTD, 0);
    builder.set_name(id, dtd_name.clone());
    builder.store.borrow_mut().nodes[id as usize].external_id = external_id.clone();
    builder.store.borrow_mut().nodes[id as usize].system_id = system_id.clone();
    builder.set_line(id, line, col);
    builder.append(0, id);
    builder.store.borrow_mut().nodes[0].internal_subset = Some(id);
    if let Some(text) = inner {
        parse_dtd_decls(builder, &text, id, true);
    }
    // DTDLOAD and DTDVALID both read the external subset. Validation reports duplicate declarations.
    // Entity declarations are registered either way so later references can resolve.
    if !html && builder.options & (DTDLOAD | DTDVALID) != 0 {
        if let Some(system) = system_id.clone() {
            let base = builder.store.borrow().nodes[0].url.clone();
            if let Some((text, path)) = read_external_subset(&base, &system) {
                if let Some(dir) = path.parent() {
                    builder.entity_base = Some(dir.to_string_lossy().into_owned());
                }
                parse_dtd_decls(builder, &text, id, false);
            }
        }
    }
    // DTDLOAD records the external subset. The node is not a child of the document.
    if !html && builder.options & DTDLOAD != 0 && (external_id.is_some() || system_id.is_some()) {
        let ext = builder.add(DTD, 0);
        builder.set_name(ext, dtd_name);
        {
            let mut store = builder.store.borrow_mut();
            store.nodes[ext as usize].external_id = external_id;
            store.nodes[ext as usize].system_id = system_id;
            store.nodes[0].external_subset = Some(ext);
        }
        builder.set_line(ext, line, col);
    }
}

fn read_external_subset(base: &Option<String>, system_id: &str) -> Option<(String, std::path::PathBuf)> {
    if system_id.contains("://") {
        return None;
    }
    let path = std::path::Path::new(system_id);
    let full = if path.is_absolute() {
        path.to_path_buf()
    } else {
        let base = base.as_ref()?;
        let base_path = std::path::Path::new(base);
        let dir = if base_path.is_file() { base_path.parent()? } else { base_path };
        dir.join(path)
    };
    let text = std::fs::read_to_string(&full).ok()?;
    Some((text, full))
}

/// `record` is true for the internal subset. The external subset only contributes validation errors.
fn parse_dtd_decls(builder: &mut Builder, text: &str, dtd_id: u32, record: bool) {
    let mut cur = Cur::new(text);
    while !cur.eof() {
        cur.skip_ws();
        if cur.eof() {
            break;
        }
        if cur.starts_with("<!--") {
            while !cur.eof() && !cur.starts_with("-->") {
                cur.bump();
            }
            cur.bump_n(3);
            continue;
        }
        if cur.starts_with("<!ENTITY") {
            cur.bump_n(8);
            parse_entity_decl(builder, &mut cur, dtd_id, record);
            continue;
        }
        if cur.starts_with("<!ELEMENT") {
            cur.bump_n(9);
            parse_element_decl(builder, &mut cur, dtd_id, record);
            continue;
        }
        if cur.starts_with("<!ATTLIST") {
            cur.bump_n(9);
            parse_attlist(builder, &mut cur, dtd_id, record);
            continue;
        }
        if cur.starts_with("<!NOTATION") {
            cur.bump_n(10);
            parse_notation_decl(builder, &mut cur, dtd_id, record);
            continue;
        }
        if cur.starts_with("<!") || cur.starts_with("<?") {
            while let Some(ch) = cur.bump() {
                if ch == '>' {
                    break;
                }
            }
            continue;
        }
        cur.bump();
    }
}

fn parse_entity_decl(builder: &mut Builder, cur: &mut Cur<'_>, dtd_id: u32, record: bool) {
    cur.skip_ws();
    let parameter = cur.peek() == Some('%');
    if parameter {
        cur.bump();
        cur.skip_ws();
    }
    let name = read_dtd_name(cur);
    if name.is_empty() {
        skip_decl_tail(cur);
        return;
    }
    cur.skip_ws();
    let mut external_id = None;
    let mut system_id = None;
    let mut notation = None;
    let mut value = None;
    let keyword = read_keyword(cur);
    if keyword.eq_ignore_ascii_case("PUBLIC") {
        cur.skip_ws();
        external_id = read_quoted(cur);
        cur.skip_ws();
        system_id = read_quoted(cur);
    } else if keyword.eq_ignore_ascii_case("SYSTEM") {
        cur.skip_ws();
        system_id = read_quoted(cur);
    } else if keyword.is_empty() {
        value = read_quoted(cur);
    }
    cur.skip_ws();
    if read_keyword(cur).eq_ignore_ascii_case("NDATA") {
        cur.skip_ws();
        notation = Some(read_dtd_name(cur));
    }
    skip_decl_tail(cur);
    if parameter {
        return;
    }
    let exists = builder.entities.iter().any(|existing| existing.name == name);
    if exists {
        return;
    }
    let (entity_type, content) = if let Some(value) = value.clone() {
        (1_i64, value)
    } else if notation.is_some() {
        (3, notation.clone().unwrap_or_default())
    } else {
        (2, String::new())
    };
    builder.entities.push(EntityRec {
        name: name.clone(),
        literal: if entity_type == 1 { Some(content.clone()) } else { None },
        system_id: system_id.clone(),
        expand: entity_type != 3,
    });
    if !record {
        return;
    }
    let id = builder.add(ENTITY_DECL, 0);
    builder.set_name(id, name);
    builder.set_content(id, content);
    {
        let mut store = builder.store.borrow_mut();
        store.nodes[id as usize].entity_type = entity_type;
        store.nodes[id as usize].external_id = external_id;
        store.nodes[id as usize].system_id = system_id;
    }
    builder.append(dtd_id, id);
}

fn parse_element_decl(builder: &mut Builder, cur: &mut Cur<'_>, dtd_id: u32, record: bool) {
    cur.skip_ws();
    let raw = read_dtd_name(cur);
    if raw.is_empty() {
        skip_decl_tail(cur);
        return;
    }
    cur.skip_ws();
    let (element_type, content_id) = parse_content_spec(builder, cur);
    skip_decl_tail(cur);
    let (prefix, local) = split_decl_name(&raw);
    if element_declared(builder, &local) || element_declared(builder, &raw) {
        if builder.options & DTDVALID != 0 {
            builder.error(
                format!("Element type \"{raw}\" must not be declared more than once."),
                cur.line,
                cur.col,
                2,
            );
        }
        return;
    }
    if !record {
        // Remember the name so a later duplicate in the same subset is reported. No node is added.
        let id = builder.add(ELEMENT_DECL, 0);
        builder.set_name(id, local);
        builder.store.borrow_mut().decls.insert(
            id,
            DeclData {
                prefix,
                element_type,
                attr_type: String::new(),
                attr_default: None,
                attr_default_kind: None,
                attr_enum: Vec::new(),
                elem_name: None,
                content_id,
            },
        );
        return;
    }
    let id = builder.add(ELEMENT_DECL, 0);
    builder.set_name(id, local);
    builder.store.borrow_mut().decls.insert(
        id,
        DeclData {
            prefix,
            element_type,
            attr_type: String::new(),
            attr_default: None,
            attr_default_kind: None,
            attr_enum: Vec::new(),
            elem_name: None,
            content_id,
        },
    );
    builder.append(dtd_id, id);
}

fn element_declared(builder: &Builder, name: &str) -> bool {
    let store = builder.store.borrow();
    store.nodes.iter().enumerate().any(|(index, node)| {
        if node.kind != ELEMENT_DECL {
            return false;
        }
        if node.name.as_deref() == Some(name) {
            return true;
        }
        let Some(prefix) = store.decls.get(&(index as u32)).and_then(|decl| decl.prefix.as_deref()) else {
            return false;
        };
        let local = node.name.as_deref().unwrap_or("");
        name.starts_with(prefix) && name.as_bytes().get(prefix.len()) == Some(&b':') && name.ends_with(local)
    })
}

fn parse_attlist(builder: &mut Builder, cur: &mut Cur<'_>, dtd_id: u32, record: bool) {
    cur.skip_ws();
    let element_name = read_dtd_name(cur);
    if element_name.is_empty() {
        skip_decl_tail(cur);
        return;
    }
    loop {
        cur.skip_ws();
        if cur.peek() == Some('>') || cur.eof() {
            if cur.peek() == Some('>') {
                cur.bump();
            }
            break;
        }
        let attr_name = read_dtd_name(cur);
        if attr_name.is_empty() {
            skip_decl_tail(cur);
            break;
        }
        cur.skip_ws();
        let (attr_type, enumeration) = if cur.peek() == Some('(') {
            let list = read_enumeration(cur);
            let rendered = format!("({})", list.join("|"));
            (rendered, list)
        } else {
            (read_dtd_name(cur), Vec::new())
        };
        cur.skip_ws();
        let mut default = None;
        let mut default_kind = None;
        if cur.starts_with("#") {
            cur.bump();
            let keyword = read_dtd_name(cur);
            if keyword.eq_ignore_ascii_case("FIXED") {
                default_kind = Some("FIXED".to_string());
                cur.skip_ws();
                default = read_quoted(cur);
            } else if keyword.eq_ignore_ascii_case("REQUIRED") {
                default_kind = Some("REQUIRED".to_string());
            } else if keyword.eq_ignore_ascii_case("IMPLIED") {
                default_kind = Some("IMPLIED".to_string());
            }
        } else {
            default = read_quoted(cur);
        }
        if !record {
            continue;
        }
        let id = builder.add(ATTRIBUTE_DECL, 0);
        builder.set_name(id, attr_name);
        builder.store.borrow_mut().decls.insert(
            id,
            DeclData {
                prefix: None,
                element_type: 0,
                attr_type,
                attr_default: default,
                attr_default_kind: default_kind,
                attr_enum: enumeration,
                elem_name: Some(element_name.clone()),
                content_id: None,
            },
        );
        builder.append(dtd_id, id);
    }
}

fn parse_notation_decl(builder: &mut Builder, cur: &mut Cur<'_>, dtd_id: u32, _record: bool) {
    cur.skip_ws();
    let name = read_dtd_name(cur);
    if name.is_empty() {
        skip_decl_tail(cur);
        return;
    }
    cur.skip_ws();
    let keyword = read_keyword(cur);
    cur.skip_ws();
    let mut public_id = None;
    let mut system_id = None;
    if keyword.eq_ignore_ascii_case("PUBLIC") {
        public_id = read_quoted(cur);
        cur.skip_ws();
        if cur.peek() == Some('"') || cur.peek() == Some('\'') {
            system_id = read_quoted(cur);
        }
    } else if keyword.eq_ignore_ascii_case("SYSTEM") {
        system_id = read_quoted(cur);
    }
    skip_decl_tail(cur);
    let duplicate = builder.store.borrow().notations.iter().any(|note| note.dtd == dtd_id && note.name == name);
    if duplicate {
        if builder.options & DTDVALID != 0 {
            builder.error(
                format!(
                    "The declaration for the notation \"{name}\" is not unique. A given Name must not be declared in more than one notation declaration."
                ),
                cur.line,
                cur.col,
                2,
            );
        }
        return;
    }
    builder.store.borrow_mut().notations.push(Notation { dtd: dtd_id, name, public_id, system_id });
}

fn read_enumeration(cur: &mut Cur<'_>) -> Vec<String> {
    let mut items = Vec::new();
    if cur.peek() == Some('(') {
        cur.bump();
    }
    loop {
        cur.skip_ws();
        let name = read_dtd_name(cur);
        if !name.is_empty() {
            items.push(name);
        }
        cur.skip_ws();
        if cur.peek() == Some('|') {
            cur.bump();
            continue;
        }
        if cur.peek() == Some(')') {
            cur.bump();
        }
        break;
    }
    items
}

fn read_dtd_name(cur: &mut Cur<'_>) -> String {
    let mut out = String::new();
    while let Some(ch) = cur.peek() {
        if out.is_empty() {
            if !(ch.is_ascii_alphabetic() || ch == '_' || ch == ':' || ch == '#') {
                break;
            }
        } else if !(ch.is_ascii_alphanumeric() || ch == '_' || ch == ':' || ch == '-' || ch == '.' || ch == '#') {
            break;
        }
        out.push(ch);
        cur.bump();
    }
    out
}

fn skip_decl_tail(cur: &mut Cur<'_>) {
    while let Some(ch) = cur.peek() {
        if ch == '>' {
            cur.bump();
            break;
        }
        cur.bump();
    }
}

fn split_decl_name(name: &str) -> (Option<String>, String) {
    match name.split_once(':') {
        Some((prefix, local)) if !prefix.is_empty() && !local.is_empty() && !local.contains(':') => {
            (Some(prefix.to_string()), local.to_string())
        }
        _ => (None, name.to_string()),
    }
}

fn parse_content_spec(builder: &mut Builder, cur: &mut Cur<'_>) -> (i32, Option<u32>) {
    cur.skip_ws();
    if cur.starts_with("EMPTY") {
        cur.bump_n(5);
        return (ELEM_EMPTY, None);
    }
    if cur.starts_with("ANY") {
        cur.bump_n(3);
        return (ELEM_ANY, None);
    }
    if cur.peek() != Some('(') {
        return (ELEM_EMPTY, None);
    }
    cur.bump();
    cur.skip_ws();
    if cur.starts_with("#PCDATA") {
        let id = push_content(
            builder,
            ContentNode { name: None, prefix: None, kind: CONTENT_PCDATA, occur: OCCUR_ONCE, c1: None, c2: None },
        );
        while let Some(ch) = cur.peek() {
            if ch == '>' {
                break;
            }
            cur.bump();
        }
        return (ELEM_MIXED, Some(id));
    }
    let id = parse_content_group(builder, cur);
    (ELEM_CHILDREN, Some(id))
}

fn parse_content_group(builder: &mut Builder, cur: &mut Cur<'_>) -> u32 {
    let mut items = vec![parse_content_cp(builder, cur)];
    let mut separator = None;
    loop {
        cur.skip_ws();
        let sep = cur.peek();
        if sep != Some(',') && sep != Some('|') {
            break;
        }
        separator = sep;
        cur.bump();
        items.push(parse_content_cp(builder, cur));
    }
    cur.skip_ws();
    if cur.peek() == Some(')') {
        cur.bump();
    }
    let occur = read_occurrence(cur);
    if items.len() == 1 {
        set_content_occur(builder, items[0], occur);
        return items[0];
    }
    let kind = if separator == Some('|') { CONTENT_OR } else { CONTENT_SEQ };
    let mut acc = items.pop().unwrap();
    while let Some(left) = items.pop() {
        acc = push_content(
            builder,
            ContentNode { name: None, prefix: None, kind, occur: OCCUR_ONCE, c1: Some(left), c2: Some(acc) },
        );
    }
    set_content_occur(builder, acc, occur);
    acc
}

fn parse_content_cp(builder: &mut Builder, cur: &mut Cur<'_>) -> u32 {
    cur.skip_ws();
    if cur.peek() == Some('(') {
        cur.bump();
        return parse_content_group(builder, cur);
    }
    let raw = read_dtd_name(cur);
    let occur = read_occurrence(cur);
    let (prefix, local) = split_decl_name(&raw);
    push_content(
        builder,
        ContentNode { name: Some(local), prefix, kind: CONTENT_ELEMENT, occur, c1: None, c2: None },
    )
}

fn read_occurrence(cur: &mut Cur<'_>) -> i32 {
    match cur.peek() {
        Some('?') => {
            cur.bump();
            OCCUR_OPT
        }
        Some('*') => {
            cur.bump();
            OCCUR_MULT
        }
        Some('+') => {
            cur.bump();
            OCCUR_PLUS
        }
        _ => OCCUR_ONCE,
    }
}

fn push_content(builder: &mut Builder, node: ContentNode) -> u32 {
    let mut store = builder.store.borrow_mut();
    let id = store.contents.len() as u32;
    store.contents.push(node);
    id
}

fn set_content_occur(builder: &mut Builder, id: u32, occur: i32) {
    builder.store.borrow_mut().contents[id as usize].occur = occur;
}

fn read_keyword(cur: &mut Cur<'_>) -> String {
    let mut out = String::new();
    while let Some(ch) = cur.peek() {
        if !ch.is_ascii_alphabetic() {
            break;
        }
        out.push(ch);
        cur.bump();
    }
    out
}

fn read_quoted(cur: &mut Cur<'_>) -> Option<String> {
    let quote = cur.peek()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    cur.bump();
    let mut out = String::new();
    while let Some(ch) = cur.bump() {
        if ch == quote {
            break;
        }
        out.push(ch);
    }
    Some(out)
}

fn parse_start_tag(builder: &mut Builder, cur: &mut Cur<'_>, parent: u32, html: bool) -> Option<u32> {
    let line = cur.line;
    let col = cur.col;
    cur.bump();
    if !cur.peek().is_some_and(is_name_start) {
        builder.error("Start tag expected, '<' not found", line, col, 3);
        return None;
    }
    let mut name = String::new();
    while let Some(ch) = cur.peek() {
        if !is_name_char(ch) {
            break;
        }
        name.push(ch);
        cur.bump();
    }
    if html {
        name = name.to_ascii_lowercase();
    }
    let id = builder.add(ELEMENT, 0);
    builder.set_name(id, name.clone());
    builder.set_line(id, line, col);
    builder.append(parent, id);
    let mut self_closing = false;
    loop {
        cur.skip_ws();
        if cur.starts_with("/>") {
            self_closing = true;
            cur.bump_n(2);
            break;
        }
        if cur.peek() == Some('>') {
            cur.bump();
            break;
        }
        if cur.eof() {
            builder.error(format!("Couldn't find end of Start Tag {name}"), line, col, 3);
            break;
        }
        if !cur.peek().is_some_and(is_name_start) {
            cur.bump();
            continue;
        }
        let mut attr_name = String::new();
        while let Some(ch) = cur.peek() {
            if !is_name_char(ch) {
                break;
            }
            attr_name.push(ch);
            cur.bump();
        }
        if html {
            attr_name = attr_name.to_ascii_lowercase();
        }
        cur.skip_ws();
        let value = if cur.peek() == Some('=') {
            cur.bump();
            cur.skip_ws();
            let raw = read_attr_value(cur, html);
            if html { raw } else { expand_general_entities(&raw, &builder.entities) }
        } else if html {
            attr_name.clone()
        } else {
            builder.error(format!("AttValue: \" or ' expected"), cur.line, cur.col, 3);
            String::new()
        };
        if !html && (attr_name == "xmlns" || attr_name.starts_with("xmlns:")) {
            let prefix = if attr_name == "xmlns" {
                None
            } else {
                Some(attr_name[6..].to_string())
            };
            builder.define_ns(id, prefix, value);
        } else {
            let attr = builder.add(ATTRIBUTE, 0);
            builder.set_name(attr, attr_name);
            builder.set_content(attr, value);
            builder.set_line(attr, line, col);
            builder.append(id, attr);
        }
    }
    if !html {
        let attrs = builder.store.borrow().nodes[id as usize].attrs.clone();
        builder.bind_element_ns(id);
        for attr in attrs {
            builder.bind_attr_ns(id, attr);
        }
    }
    if self_closing || (html && is_void(&builder.store.borrow().nodes[id as usize].name.clone().unwrap_or_default())) {
        builder.store.borrow_mut().nodes[id as usize].content = "\u{0}empty".to_string();
    }
    Some(id)
}

fn read_attr_value(cur: &mut Cur<'_>, html: bool) -> String {
    let quote = cur.peek();
    if quote == Some('"') || quote == Some('\'') {
        let quote = quote.unwrap();
        cur.bump();
        let mut out = String::new();
        while let Some(ch) = cur.peek() {
            if ch == quote {
                cur.bump();
                break;
            }
            if ch == '&' {
                if let Some(decoded) = read_entity_chars(cur, html) {
                    out.push_str(&decoded);
                    continue;
                }
            }
            out.push(ch);
            cur.bump();
        }
        return out;
    }
    let mut out = String::new();
    while let Some(ch) = cur.peek() {
        if ch.is_whitespace() || ch == '>' || ch == '/' {
            break;
        }
        out.push(ch);
        cur.bump();
    }
    out
}

fn read_entity_chars(cur: &mut Cur<'_>, html: bool) -> Option<String> {
    if cur.peek() != Some('&') {
        return None;
    }
    let saved_i = cur.i;
    let saved_line = cur.line;
    let saved_col = cur.col;
    cur.bump();
    let mut body = String::new();
    while let Some(ch) = cur.peek() {
        if ch == ';' {
            cur.bump();
            break;
        }
        if ch.is_whitespace() || ch == '<' || body.len() > 32 {
            cur.i = saved_i;
            cur.line = saved_line;
            cur.col = saved_col;
            return None;
        }
        body.push(ch);
        cur.bump();
    }
    let ch = if body.starts_with('#') {
        decode_decimal(&body).or_else(|| decode_numeric(&body))
    } else if html {
        html_entity(&body).or_else(|| xml_predefined(&body))
    } else {
        xml_predefined(&body)
    };
    ch.map(|c| c.to_string()).or_else(|| {
        cur.i = saved_i;
        cur.line = saved_line;
        cur.col = saved_col;
        None
    })
}

fn parse_reference(builder: &mut Builder, cur: &mut Cur<'_>, parent: u32, html: bool) {
    let line = cur.line;
    let col = cur.col;
    if let Some(text) = read_entity_chars(cur, html) {
        builder.add_text(parent, &text, line, col);
        return;
    }
    cur.bump();
    let mut name = String::new();
    while let Some(ch) = cur.peek() {
        if ch == ';' {
            cur.bump();
            break;
        }
        if ch.is_whitespace() || ch == '<' {
            break;
        }
        name.push(ch);
        cur.bump();
    }
    let record = builder.entities.iter().find(|item| item.name == name).cloned();
    if let Some(record) = record {
        let noent = builder.options & NOENT != 0;
        if noent && record.expand {
            if let Some(value) = record.literal.clone() {
                if value.contains('<') {
                    insert_replacement(builder, parent, &value);
                } else {
                    builder.add_text(parent, &entity_replacement_text(&value), line, col);
                }
            } else if let Some(system) = record.system_id.clone() {
                if let Some(text) = load_system_entity(builder, &system) {
                    insert_replacement(builder, parent, &text);
                }
            }
            return;
        }
        let id = builder.add(ENTITY_REF, 0);
        builder.set_name(id, name);
        if let Some(value) = &record.literal {
            builder.set_content(id, entity_replacement_text(value));
        }
        builder.set_line(id, line, col);
        builder.append(parent, id);
        return;
    }
    if html {
        if let Some(ch) = html_entity(&name) {
            builder.add_text(parent, &ch.to_string(), line, col);
            return;
        }
        builder.add_text(parent, &format!("&{name};"), line, col);
        return;
    }
    builder.error(format!("Entity '{name}' not defined"), line, col, 3);
    if builder.options & NOENT != 0 {
        return;
    }
    let id = builder.add(ENTITY_REF, 0);
    builder.set_name(id, name.clone());
    builder.set_content(id, String::new());
    builder.set_line(id, line, col);
    builder.append(parent, id);
}

fn load_system_entity(builder: &Builder, system_id: &str) -> Option<String> {
    let base = if builder.entity_base.is_some() {
        builder.entity_base.clone()
    } else {
        builder.store.borrow().nodes[0].url.clone()
    };
    read_external_subset(&base, system_id).map(|(text, _path)| text)
}

fn insert_replacement(builder: &mut Builder, parent: u32, markup: &str) {
    let parsed = parse_xml(markup, None, None, RECOVER, 0);
    let src = parsed.store.borrow();
    let children: Vec<u32> = src.nodes[0]
        .children
        .iter()
        .copied()
        .filter(|&child| {
            let node = &src.nodes[child as usize];
            if node.kind == DTD {
                return false;
            }
            if node.kind == PI && node.name.as_deref() == Some("xml") {
                return false;
            }
            true
        })
        .collect();
    let mut dest = builder.store.borrow_mut();
    let owner = dest.nodes[parent as usize].owner;
    for child in children {
        let new_id = copy_subtree(&src, &mut dest, child, owner, true);
        dest.append_child(parent, new_id);
    }
}

fn expand_general_entities(value: &str, entities: &[EntityRec]) -> String {
    let mut current = value.to_string();
    for _ in 0..8 {
        let mut next = String::new();
        let mut changed = false;
        let mut index = 0;
        let bytes = current.as_bytes().to_vec();
        while index < bytes.len() {
            if bytes[index] == b'&' {
                if let Some(end) = current[index + 1..].find(';') {
                    let name = &current[index + 1..index + 1 + end];
                    if let Some(replacement) = entities.iter().find(|item| item.name == name).and_then(|item| item.literal.clone()) {
                        next.push_str(&replacement);
                        changed = true;
                        index = index + 1 + end + 1;
                        continue;
                    }
                }
            }
            let ch = current[index..].chars().next().unwrap_or('\u{fffd}');
            next.push(ch);
            index += ch.len_utf8();
        }
        current = next;
        if !changed {
            break;
        }
    }
    current
}

fn entity_replacement_text(value: &str) -> String {
    let mut out = String::new();
    let mut rest = value;
    while !rest.is_empty() {
        if rest.starts_with("<?") {
            if let Some(end) = rest.find("?>") {
                let body = &rest[2..end];
                if let Some(space) = body.find(char::is_whitespace) {
                    out.push_str(body[space..].trim_start());
                }
                rest = &rest[end + 2..];
                continue;
            }
        }
        if rest.starts_with("<!--") {
            if let Some(end) = rest.find("-->") {
                rest = &rest[end + 3..];
                continue;
            }
        }
        if rest.starts_with('<') {
            if let Some(end) = rest.find('>') {
                rest = &rest[end + 1..];
                continue;
            }
        }
        let ch = rest.chars().next().unwrap();
        out.push(ch);
        rest = &rest[ch.len_utf8()..];
    }
    out
}

fn element_names_in_markup(value: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut rest = value;
    while let Some(start) = rest.find('<') {
        rest = &rest[start..];
        if rest.starts_with("</") || rest.starts_with("<?") || rest.starts_with("<!") {
            if let Some(end) = rest.find('>') {
                rest = &rest[end + 1..];
            } else {
                break;
            }
            continue;
        }
        rest = &rest[1..];
        let mut name = String::new();
        for ch in rest.chars() {
            if ch.is_whitespace() || ch == '>' || ch == '/' {
                break;
            }
            name.push(ch);
        }
        if !name.is_empty() {
            names.push(name);
        }
        if let Some(end) = rest.find('>') {
            rest = &rest[end + 1..];
        } else {
            break;
        }
    }
    names
}

fn validate_document(builder: &mut Builder) {
    let store = builder.store.borrow();
    let dtd = store.nodes[0].internal_subset;
    let Some(dtd) = dtd else { return };
    let mut declared = HashSet::new();
    for (index, node) in store.nodes.iter().enumerate() {
        if node.kind == ELEMENT_DECL {
            if let Some(name) = node.name.clone() {
                declared.insert(name);
            }
            if let Some(prefix) = store.decls.get(&(index as u32)).and_then(|decl| decl.prefix.clone()) {
                if let Some(name) = node.name.clone() {
                    declared.insert(format!("{prefix}:{name}"));
                }
            }
        }
    }
    let mut entities = HashMap::new();
    for child in &store.nodes[dtd as usize].children {
        let node = &store.nodes[*child as usize];
        if node.kind == ENTITY_DECL && node.entity_type == 1 {
            if let Some(name) = node.name.clone() {
                entities.insert(name, node.content.clone());
            }
        }
    }
    let mut extra = Vec::new();
    let children = store.nodes[0].children.clone();
    for child in children {
        collect_validity(&store, child, &declared, &entities, &mut extra);
    }
    drop(store);
    builder.errors.extend(extra);
}

fn collect_validity(
    store: &Store,
    id: u32,
    declared: &HashSet<String>,
    entities: &HashMap<String, String>,
    errors: &mut Vec<ParseError>,
) {
    let kind = store.nodes[id as usize].kind;
    if kind == ELEMENT {
        let name = store.nodes[id as usize].name.clone().unwrap_or_default();
        if !declared.contains(&name) {
            errors.push(ParseError {
                message: format!("Element type \"{name}\" must be declared."),
                line: store.nodes[id as usize].line,
                column: store.nodes[id as usize].column,
                level: 2,
                domain: 1,
                code: 1,
            });
        }
        let children = store.nodes[id as usize].children.clone();
        for child in children {
            collect_validity(store, child, declared, entities, errors);
        }
        return;
    }
    if kind == ENTITY_REF {
        let name = store.nodes[id as usize].name.clone().unwrap_or_default();
        if let Some(value) = entities.get(&name) {
            for element in element_names_in_markup(value) {
                if !declared.contains(&element) {
                    errors.push(ParseError {
                        message: format!("Element type \"{element}\" must be declared."),
                        line: store.nodes[id as usize].line,
                        column: store.nodes[id as usize].column,
                        level: 2,
                        domain: 1,
                        code: 1,
                    });
                }
            }
        }
        return;
    }
    if matches!(kind, crate::store::DOCUMENT | crate::store::HTML_DOCUMENT) {
        let children = store.nodes[id as usize].children.clone();
        for child in children {
            collect_validity(store, child, declared, entities, errors);
        }
    }
}

fn close_tag(builder: &mut Builder, cur: &mut Cur<'_>, open: &mut Vec<(u32, String, i64)>, html: bool) {
    let line = cur.line;
    let col = cur.col;
    cur.bump_n(2);
    let mut name = String::new();
    while let Some(ch) = cur.peek() {
        if !is_name_char(ch) {
            break;
        }
        name.push(ch);
        cur.bump();
    }
    if html {
        name = name.to_ascii_lowercase();
    }
    while let Some(ch) = cur.peek() {
        if ch == '>' {
            cur.bump();
            break;
        }
        cur.bump();
    }
    if html {
        while let Some((_, open_name, _)) = open.last() {
            if open_name == &name || optional_end(open_name) {
                let matches = open_name == &name;
                open.pop();
                if matches {
                    break;
                }
            } else {
                break;
            }
        }
        return;
    }
    let (end_prefix, end_local) = match name.split_once(':') {
        Some((prefix, local)) if !prefix.is_empty() && !local.is_empty() => (Some(prefix.to_string()), local.to_string()),
        _ => (None, name.clone()),
    };
    let same_open = |id: u32, open_name: &str| {
        if open_name != end_local {
            return false;
        }
        let store = builder.store.borrow();
        let prefix = store.nodes[id as usize].ns.and_then(|ns| store.nss[ns as usize].prefix.clone());
        prefix.as_deref() == end_prefix.as_deref()
    };
    if let Some(index) = open.iter().rposition(|(id, open_name, _)| same_open(*id, open_name)) {
        if index + 1 != open.len() {
            if let Some((_, open_name, open_line)) = open.last() {
                let _ = open_line;
                builder.error(
                    format!("The element type \"{open_name}\" must be terminated by the matching end-tag \"</{open_name}>\"."),
                    line,
                    col,
                    3,
                );
            }
        }
        open.truncate(index);
    } else if let Some((_, open_name, open_line)) = open.last() {
        builder.error(
            format!("The element type \"{open_name}\" must be terminated by the matching end-tag \"</{open_name}>\"."),
            line,
            col,
            3,
        );
    } else {
        builder.error(format!("Unexpected end tag : {name}"), line, col, 3);
    }
}

fn optional_end(name: &str) -> bool {
    matches!(name, "p" | "li" | "dt" | "dd" | "tr" | "td" | "th" | "option" | "thead" | "tbody" | "tfoot")
}

fn is_void(name: &str) -> bool {
    matches!(
        name,
        "area" | "base" | "basefont" | "bgsound" | "br" | "col" | "embed" | "frame" | "hr"
            | "img" | "input" | "keygen" | "link" | "meta" | "param" | "source" | "track" | "wbr"
            | "isindex"
    )
}

fn head_only(name: &str) -> bool {
    matches!(name, "title" | "meta" | "link" | "base" | "style")
}

fn closes_p(name: &str) -> bool {
    matches!(
        name,
        "address" | "article" | "aside" | "blockquote" | "div" | "dl" | "fieldset" | "footer"
            | "form" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "header" | "hr" | "main" | "nav"
            | "ol" | "p" | "pre" | "section" | "table" | "ul"
    )
}

fn raw_text(name: &str) -> bool {
    matches!(name, "script" | "style" | "textarea" | "title" | "xmp" | "iframe" | "noembed" | "noframes" | "noscript" | "plaintext")
}

fn parse_html_tree(builder: &mut Builder, input: &str) {
    let mut cur = Cur::new(input);
    if cur.starts_with("\u{feff}") {
        cur.bump();
    }
    let mut saw_doctype = false;
    let html = builder.add(ELEMENT, 0);
    builder.set_name(html, "html");
    builder.append(0, html);
    let mut head: Option<u32> = None;
    let mut body: Option<u32> = None;
    let mut stack: Vec<u32> = vec![html];
    let mut saw_head_element = false;

    let ensure_body = |builder: &mut Builder, body: &mut Option<u32>, stack: &mut Vec<u32>, html: u32| {
        if body.is_none() {
            let id = builder.add(ELEMENT, 0);
            builder.set_name(id, "body");
            builder.append(html, id);
            *body = Some(id);
            stack.clear();
            stack.push(html);
            stack.push(id);
        } else if !stack.iter().any(|id| builder.store.borrow().nodes[*id as usize].name.as_deref() == Some("body")) {
            stack.clear();
            stack.push(html);
            stack.push(body.unwrap());
        }
    };

    while !cur.eof() {
        if cur.starts_with("<!--") {
            let parent = *stack.last().unwrap_or(&html);
            parse_comment(builder, &mut cur, parent);
            continue;
        }
        if cur.starts_with("<!DOCTYPE") || cur.starts_with("<!doctype") {
            parse_doctype(builder, &mut cur, true);
            saw_doctype = true;
            let dtd = builder.store.borrow().nodes[0].internal_subset;
            if let Some(dtd) = dtd {
                builder.store.borrow_mut().insert_before(html, dtd);
            }
            continue;
        }
        if cur.starts_with("<!") {
            // Conditional comments such as <![if foo]> are dropped on the non-libxml path.
            while let Some(ch) = cur.peek() {
                cur.bump();
                if ch == '>' {
                    break;
                }
            }
            continue;
        }
        if cur.starts_with("</") {
            let mut name = String::new();
            let saved = cur.i;
            let saved_line = cur.line;
            let saved_col = cur.col;
            cur.bump_n(2);
            while let Some(ch) = cur.peek() {
                if !is_name_char(ch) {
                    break;
                }
                name.push(ch);
                cur.bump();
            }
            name = name.to_ascii_lowercase();
            cur.i = saved;
            cur.line = saved_line;
            cur.col = saved_col;
            let open: Vec<(u32, String, i64)> = stack
                .iter()
                .map(|id| {
                    let name = builder.store.borrow().nodes[*id as usize].name.clone().unwrap_or_default();
                    (*id, name, 1)
                })
                .collect();
            let mut open = open;
            close_tag(builder, &mut cur, &mut open, true);
            stack = open.into_iter().map(|(id, _, _)| id).collect();
            continue;
        }
        if cur.starts_with("<") {
            let parent_before = *stack.last().unwrap_or(&html);
            let Some(id) = parse_start_tag(builder, &mut cur, parent_before, true) else {
                continue;
            };
            let empty = builder.store.borrow().nodes[id as usize].content == "\u{0}empty";
            if empty {
                builder.store.borrow_mut().nodes[id as usize].content.clear();
            }
            let name = builder.store.borrow().nodes[id as usize].name.clone().unwrap_or_default();
            if name == "html" {
                builder.store.borrow_mut().unlink(id);
                let attrs = builder.store.borrow().nodes[id as usize].attrs.clone();
                for attr in attrs {
                    builder.store.borrow_mut().append_child(html, attr);
                }
                continue;
            }
            if name == "head" {
                builder.store.borrow_mut().unlink(id);
                if head.is_none() {
                    builder.store.borrow_mut().append_child(html, id);
                    head = Some(id);
                    saw_head_element = true;
                }
                stack.clear();
                stack.push(html);
                stack.push(head.unwrap());
                continue;
            }
            if name == "body" {
                builder.store.borrow_mut().unlink(id);
                if body.is_none() {
                    builder.store.borrow_mut().append_child(html, id);
                    body = Some(id);
                }
                stack.clear();
                stack.push(html);
                stack.push(body.unwrap());
                let attrs = {
                    let store = builder.store.borrow();
                    store.nodes[id as usize].attrs.clone()
                };
                for attr in attrs {
                    builder.append(body.unwrap(), attr);
                }
                continue;
            }
            builder.store.borrow_mut().unlink(id);
            if head_only(&name) && body.is_none() {
                if head.is_none() {
                    let head_id = builder.add(ELEMENT, 0);
                    builder.set_name(head_id, "head");
                    builder.append(html, head_id);
                    head = Some(head_id);
                    saw_head_element = true;
                }
                builder.append(head.unwrap(), id);
                if !empty {
                    stack.clear();
                    stack.push(html);
                    stack.push(head.unwrap());
                    stack.push(id);
                }
            } else {
                if stack.iter().any(|node| builder.store.borrow().nodes[*node as usize].name.as_deref() == Some("p"))
                    && closes_p(&name)
                {
                    while let Some(node) = stack.last().copied() {
                        let node_name = builder.store.borrow().nodes[node as usize].name.clone().unwrap_or_default();
                        if node_name == "p" {
                            stack.pop();
                            break;
                        }
                        if node_name == "html" || node_name == "body" {
                            break;
                        }
                        stack.pop();
                    }
                }
                ensure_body(builder, &mut body, &mut stack, html);
                let parent = *stack.last().unwrap_or(&html);
                builder.append(parent, id);
                if !empty {
                    stack.push(id);
                }
            }
            if raw_text(&name) && !empty {
                let decode = matches!(name.as_str(), "textarea" | "title");
                let mut text = String::new();
                let end = format!("</{name}");
                let line = cur.line;
                let col = cur.col;
                loop {
                    if cur.rest().to_ascii_lowercase().starts_with(&end) {
                        break;
                    }
                    if cur.eof() {
                        break;
                    }
                    if decode && cur.peek() == Some('&') {
                        if let Some(decoded) = read_entity_chars(&mut cur, true) {
                            text.push_str(&decoded);
                            continue;
                        }
                    }
                    if let Some(ch) = cur.bump() {
                        text.push(ch);
                    }
                }
                if !text.is_empty() {
                    builder.add_text(id, &text, line, col);
                }
            }
            continue;
        }
        let line = cur.line;
        let col = cur.col;
        let mut text = String::new();
        while let Some(ch) = cur.peek() {
            if ch == '<' {
                break;
            }
            if ch == '&' {
                break;
            }
            text.push(ch);
            cur.bump();
        }
        if !text.is_empty() && !text.chars().all(char::is_whitespace) || (body.is_some() && !text.is_empty()) {
            if body.is_none() && text.chars().all(char::is_whitespace) {
                continue;
            }
            ensure_body(builder, &mut body, &mut stack, html);
            let parent = *stack.last().unwrap_or(&html);
            builder.add_text(parent, &text, line, col);
        } else if text.chars().all(char::is_whitespace) {
            // Drop leading document whitespace.
        }
        if cur.peek() == Some('&') {
            ensure_body(builder, &mut body, &mut stack, html);
            let parent = *stack.last().unwrap_or(&html);
            parse_reference(builder, &mut cur, parent, true);
        }
    }

    if !saw_doctype {
        let id = builder.add(DTD, 0);
        builder.set_name(id, "html");
        builder.store.borrow_mut().nodes[id as usize].external_id =
            Some("-//W3C//DTD HTML 4.0 Transitional//EN".to_string());
        builder.store.borrow_mut().nodes[id as usize].system_id =
            Some("http://www.w3.org/TR/REC-html40/loose.dtd".to_string());
        builder.store.borrow_mut().insert_before(html, id);
        builder.store.borrow_mut().nodes[0].internal_subset = Some(id);
    }
    if saw_head_element {
        if let Some(head_id) = head.or_else(|| {
            builder.store.borrow().nodes[html as usize].children.iter().copied().find(|id| {
                builder.store.borrow().nodes[*id as usize].name.as_deref() == Some("head")
            })
        }) {
            let head_children = builder.store.borrow().nodes[head_id as usize].children.clone();
            let has_meta = head_children.iter().any(|child| {
                let store = builder.store.borrow();
                let node = &store.nodes[*child as usize];
                node.name.as_deref() == Some("meta")
                    && node.attrs.iter().any(|attr| {
                        store.nodes[*attr as usize].name.as_deref() == Some("http-equiv")
                    })
            });
            if !has_meta {
                let meta = builder.add(ELEMENT, 0);
                builder.set_name(meta, "meta");
                let equiv = builder.add(ATTRIBUTE, 0);
                builder.set_name(equiv, "http-equiv");
                builder.set_content(equiv, "Content-Type");
                builder.append(meta, equiv);
                let content = builder.add(ATTRIBUTE, 0);
                builder.set_name(content, "content");
                let charset = builder.store.borrow().nodes[0].encoding.clone().unwrap_or_else(|| "UTF-8".to_string());
                builder.set_content(content, format!("text/html; charset={charset}"));
                builder.append(meta, content);
                let first = builder.store.borrow().nodes[head_id as usize].children.first().copied();
                if let Some(first) = first {
                    builder.store.borrow_mut().insert_before(first, meta);
                } else {
                    builder.append(head_id, meta);
                }
            }
        }
    }
}

/// Parse a fragment in the namespace scope of `context`.
pub fn parse_fragment(input: &str, store: &Rc<RefCell<Store>>, context: u32, html: bool, options: i32) -> FragmentResult {
    let decls = if html {
        String::new()
    } else {
        context_ns_decls(&store.borrow(), context)
    };
    let wrapped = if html {
        format!("<html><body>{input}</body></html>")
    } else {
        format!("<root{decls}>{input}</root>")
    };
    let parsed = if html {
        parse_html(&wrapped, None, None, options | RECOVER, store.borrow().key.wrapping_add(1))
    } else {
        parse_xml(&wrapped, None, None, options | RECOVER, store.borrow().key.wrapping_add(1))
    };
    let root = parsed.store.borrow().root_element(0);
    let Some(root) = root else {
        return FragmentResult { ids: Vec::new(), errors: parsed.errors };
    };
    let source_parent = if html {
        parsed
            .store
            .borrow()
            .nodes[root as usize]
            .children
            .iter()
            .copied()
            .find(|id| parsed.store.borrow().nodes[*id as usize].name.as_deref() == Some("body"))
            .unwrap_or(root)
    } else {
        root
    };
    let children = parsed.store.borrow().nodes[source_parent as usize].children.clone();
    let mut ids = Vec::new();
    let owner = store.borrow().nodes[context as usize].owner;
    for child in children {
        if parsed.store.borrow().nodes[child as usize].kind == DTD {
            continue;
        }
        let new_id = {
            let src = parsed.store.borrow();
            let mut dest = store.borrow_mut();
            crate::store::copy_subtree(&src, &mut dest, child, owner, true)
        };
        inherit_context_ns(store, context, new_id);
        retarget_context_ns(store, context, new_id);
        ids.push(new_id);
    }
    FragmentResult { ids, errors: parsed.errors }
}

fn context_ns_decls(store: &Store, context: u32) -> String {
    let mut decls = String::new();
    for id in store.namespace_scopes(context) {
        let ns = &store.nss[id as usize];
        let href = ns.href.replace('&', "&amp;").replace('"', "&quot;").replace('<', "&lt;");
        match &ns.prefix {
            Some(prefix) => {
                decls.push_str(" xmlns:");
                decls.push_str(prefix);
                decls.push_str("=\"");
                decls.push_str(&href);
                decls.push('"');
            }
            None => {
                decls.push_str(" xmlns=\"");
                decls.push_str(&href);
                decls.push('"');
            }
        }
    }
    decls
}

fn retarget_context_ns(store: &Rc<RefCell<Store>>, context: u32, id: u32) {
    let kind = store.borrow().nodes[id as usize].kind;
    if kind == ELEMENT || kind == ATTRIBUTE {
        let current = store.borrow().nodes[id as usize].ns;
        if let Some(current) = current {
            let (prefix, href) = {
                let store_ref = store.borrow();
                let ns = &store_ref.nss[current as usize];
                (ns.prefix.clone(), ns.href.clone())
            };
            let found = store.borrow().lookup_ns(context, prefix.as_deref());
            if let Some(found) = found {
                let matches = {
                    let store_ref = store.borrow();
                    let ns = &store_ref.nss[found as usize];
                    ns.href == href && ns.prefix == prefix
                };
                if matches {
                    store.borrow_mut().nodes[id as usize].ns = Some(found);
                }
            }
        }
    }
    let children = store.borrow().nodes[id as usize].children.clone();
    let attrs = store.borrow().nodes[id as usize].attrs.clone();
    for child in children {
        retarget_context_ns(store, context, child);
    }
    for attr in attrs {
        retarget_context_ns(store, context, attr);
    }
}

fn inherit_context_ns(store: &Rc<RefCell<Store>>, context: u32, id: u32) {
    let kind = store.borrow().nodes[id as usize].kind;
    if kind == ELEMENT {
        let needs_ns = store.borrow().nodes[id as usize].ns.is_none();
        let name = store.borrow().nodes[id as usize].name.clone().unwrap_or_default();
        if needs_ns && !name.contains(':') {
            let (ns, defines_default) = {
                let store_ref = store.borrow();
                let ns = store_ref.lookup_ns(context, None);
                let defines_default = store_ref.nodes[id as usize].ns_defs.iter().any(|def| {
                    store_ref.nss[*def as usize].prefix.is_none()
                });
                (ns, defines_default)
            };
            if let Some(ns) = ns {
                if !defines_default {
                    store.borrow_mut().nodes[id as usize].ns = Some(ns);
                }
            }
        }
    }
    let children = store.borrow().nodes[id as usize].children.clone();
    for child in children {
        inherit_context_ns(store, context, child);
    }
}
