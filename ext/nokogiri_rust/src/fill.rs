//! One forward scan that fills flat XML records.
//!
//! The scan accepts the same documents as the Ruby flat reader: elements,
//! text, quoted attributes, namespace declarations, and predefined entities.
//! Anything else returns None so the Ruby reader stays the oracle.
//! Text stays as source offsets. Attribute values are decoded when they
//! contain "&".

use std::collections::HashMap;

pub const ELEMENT: i32 = 1;
pub const TEXT: i32 = 3;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Prefix {
    None,
    Slice { off: usize, len: usize },
    Xml,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Bytes {
    Slice { off: usize, len: usize },
    Owned(Vec<u8>),
    Xml,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attr {
    pub name_off: usize,
    pub name_len: usize,
    pub ns: i32,
    pub value: Bytes,
}

#[derive(Debug)]
pub struct Doc {
    pub typ: Vec<i32>,
    pub parent: Vec<i32>,
    pub nex: Vec<i32>,
    pub child: Vec<i32>,
    pub off: Vec<i32>,
    pub len: Vec<i32>,
    pub local: Vec<i32>,
    pub ns: Vec<i32>,
    pub line: Vec<i32>,
    pub text_off: Vec<i32>,
    pub text_len: Vec<i32>,
    pub tail: Vec<i32>,
    pub top_head: i32,
    pub top_tail: i32,
    pub prefixes: Vec<Prefix>,
    pub hrefs: Vec<Bytes>,
    pub attrs: Vec<Vec<Attr>>,
    pub defs: Vec<Vec<i32>>,
    /// Index of the xml:lang attribute on that element, when it has one.
    pub langs: Vec<Option<usize>>,
    pub xml_builtin: Option<i32>,
}

#[derive(Clone)]
struct Scope {
    default_ns: i32,
    prefixes: HashMap<Vec<u8>, i32>,
}

struct RawAttr {
    name_off: usize,
    name_len: usize,
    value: Bytes,
}

struct PendingNs {
    prefix: Option<(usize, usize)>,
    href: Bytes,
}

pub fn parse(bytes: &[u8], origin: usize) -> Option<Doc> {
    if origin > bytes.len() {
        return None;
    }
    let mut newlines = Vec::new();
    let mut scan = 0;
    while scan < bytes.len() {
        if bytes[scan] == b'\n' {
            newlines.push(scan);
        }
        if scan >= origin && scan + 1 < bytes.len() && bytes[scan] == b'<' {
            let mark = bytes[scan + 1];
            if mark == b'!' || mark == b'?' {
                return None;
            }
        }
        scan += 1;
    }

    let mut doc = Doc::with_capacity(bytes.len() / 16 + 8);
    let mut current = Scope { default_ns: -1, prefixes: HashMap::new() };
    let mut stack: Vec<i32> = Vec::new();
    let mut saved: Vec<Option<Scope>> = Vec::new();
    let mut nl_i = 0usize;
    let mut pos = origin;

    while pos < bytes.len() {
        if bytes[pos] != b'<' {
            let nxt = find_byte(bytes, pos, b'<').unwrap_or(bytes.len());
            if nxt > pos {
                if stack.is_empty() {
                    if !bytes[pos..nxt].iter().copied().all(is_ws) {
                        return None;
                    }
                } else {
                    if bytes[pos..nxt].contains(&b'&') && !entities_ok(&bytes[pos..nxt]) {
                        return None;
                    }
                    let line = line_at(&newlines, &mut nl_i, nxt);
                    let parent = *stack.last()?;
                    doc.push_text(parent, pos, nxt - pos, line);
                }
            }
            pos = nxt;
            continue;
        }

        if bytes.get(pos + 1) == Some(&b'/') {
            let gt = find_gt(bytes, pos)?;
            let name = end_name(bytes, pos, gt)?;
            let index = stack.pop()?;
            let off = doc.off[index as usize] as usize;
            let len = doc.len[index as usize] as usize;
            if &bytes[off..off + len] != name {
                return None;
            }
            if let Some(prev) = saved.pop()? {
                current = prev;
            }
            pos = gt + 1;
            continue;
        }

        if !bytes.get(pos + 1).copied().is_some_and(is_name_start) {
            return None;
        }
        let gt = find_gt(bytes, pos)?;
        let self_closing = gt > pos && bytes[gt - 1] == b'/';
        let name_off = pos + 1;
        let mut name_end = name_off + 1;
        while name_end < gt && is_name_byte(bytes[name_end]) {
            name_end += 1;
        }
        let name_len = name_end - name_off;
        if name_len == 0 {
            return None;
        }
        let attr_stop = if self_closing { gt - 1 } else { gt };
        if name_end > attr_stop {
            return None;
        }
        let raw_attrs = parse_attrs(bytes, name_end, attr_stop)?;
        let mut pending = Vec::new();
        let mut plain = Vec::new();
        for attr in raw_attrs {
            let name = &bytes[attr.name_off..attr.name_off + attr.name_len];
            if name == b"xmlns" {
                pending.push(PendingNs { prefix: None, href: attr.value });
            } else if let Some(prefix) = name.strip_prefix(b"xmlns:") {
                if prefix.is_empty() {
                    return None;
                }
                let off = attr.name_off + (name.len() - prefix.len());
                pending.push(PendingNs { prefix: Some((off, prefix.len())), href: attr.value });
            } else {
                plain.push(attr);
            }
        }

        let old = if pending.is_empty() { None } else { Some(current.clone()) };
        let mut declared_ids = Vec::with_capacity(pending.len());
        for item in pending {
            let id = match item.prefix {
                None => {
                    let id = doc.push_ns(Prefix::None, item.href);
                    current.default_ns = id;
                    id
                }
                Some((off, len)) => {
                    let id = doc.push_ns(Prefix::Slice { off, len }, item.href);
                    current.prefixes.insert(bytes[off..off + len].to_vec(), id);
                    id
                }
            };
            declared_ids.push(id);
        }

        let mut local = first_colon(&bytes[name_off..name_off + name_len]);
        let mut ns_id = -1;
        if local == 0 {
            if current.default_ns >= 0 {
                ns_id = current.default_ns;
            }
        } else {
            let prefix = &bytes[name_off..name_off + local as usize - 1];
            if let Some(found) = lookup(&current, &mut doc, prefix) {
                ns_id = found;
            } else {
                local = 0;
            }
        }

        let line = line_at(&newlines, &mut nl_i, pos);
        let parent = stack.last().copied().unwrap_or(-1);
        let index = doc.push_element(parent, name_off, name_len, local, ns_id, line, declared_ids);

        let mut built = Vec::with_capacity(plain.len());
        let mut lang_at = None;
        for attr in plain {
            let name = &bytes[attr.name_off..attr.name_off + attr.name_len];
            let (store_off, store_len, ns, is_lang) = classify_attr(&current, &mut doc, attr.name_off, name);
            if is_lang {
                lang_at = Some(built.len());
            }
            built.push(Attr { name_off: store_off, name_len: store_len, ns, value: attr.value });
        }
        doc.attrs[index as usize] = built;
        doc.langs[index as usize] = lang_at;

        if self_closing {
            if let Some(prev) = old {
                current = prev;
            }
        } else {
            stack.push(index);
            saved.push(old);
        }
        pos = gt + 1;
    }

    if !stack.is_empty() {
        return None;
    }
    Some(doc)
}

impl Doc {
    fn with_capacity(cap: usize) -> Self {
        Self {
            typ: Vec::with_capacity(cap),
            parent: Vec::with_capacity(cap),
            nex: Vec::with_capacity(cap),
            child: Vec::with_capacity(cap),
            off: Vec::with_capacity(cap),
            len: Vec::with_capacity(cap),
            local: Vec::with_capacity(cap),
            ns: Vec::with_capacity(cap),
            line: Vec::with_capacity(cap),
            text_off: Vec::with_capacity(cap),
            text_len: Vec::with_capacity(cap),
            tail: Vec::with_capacity(cap),
            top_head: -1,
            top_tail: -1,
            prefixes: Vec::new(),
            hrefs: Vec::new(),
            attrs: Vec::with_capacity(cap),
            defs: Vec::with_capacity(cap),
            langs: Vec::with_capacity(cap),
            xml_builtin: None,
        }
    }

    fn push_ns(&mut self, prefix: Prefix, href: Bytes) -> i32 {
        let id = self.prefixes.len() as i32;
        self.prefixes.push(prefix);
        self.hrefs.push(href);
        id
    }

    fn xml_ns(&mut self) -> i32 {
        if let Some(id) = self.xml_builtin {
            return id;
        }
        let id = self.push_ns(Prefix::Xml, Bytes::Xml);
        self.xml_builtin = Some(id);
        id
    }

    fn push_element(
        &mut self,
        parent: i32,
        name_off: usize,
        name_len: usize,
        local: i32,
        ns: i32,
        line: i32,
        defs: Vec<i32>,
    ) -> i32 {
        let index = self.typ.len() as i32;
        self.typ.push(ELEMENT);
        self.parent.push(parent);
        self.nex.push(-1);
        self.child.push(-1);
        self.off.push(name_off as i32);
        self.len.push(name_len as i32);
        self.local.push(local);
        self.ns.push(ns);
        self.line.push(line);
        self.text_off.push(-1);
        self.text_len.push(-1);
        self.tail.push(-1);
        self.attrs.push(Vec::new());
        self.defs.push(defs);
        self.langs.push(None);
        self.link(parent, index);
        index
    }

    fn push_text(&mut self, parent: i32, off: usize, len: usize, line: i32) -> i32 {
        let index = self.typ.len() as i32;
        self.typ.push(TEXT);
        self.parent.push(parent);
        self.nex.push(-1);
        self.child.push(-1);
        self.off.push(-1);
        self.len.push(0);
        self.local.push(0);
        self.ns.push(-1);
        self.line.push(line);
        self.text_off.push(off as i32);
        self.text_len.push(len as i32);
        self.tail.push(-1);
        self.attrs.push(Vec::new());
        self.defs.push(Vec::new());
        self.langs.push(None);
        self.link(parent, index);
        index
    }

    fn link(&mut self, parent: i32, index: i32) {
        if parent < 0 {
            if self.top_tail < 0 {
                self.top_head = index;
            } else {
                self.nex[self.top_tail as usize] = index;
            }
            self.top_tail = index;
            return;
        }
        let parent = parent as usize;
        if self.child[parent] < 0 {
            self.child[parent] = index;
        } else {
            let tail = self.tail[parent] as usize;
            self.nex[tail] = index;
        }
        self.tail[parent] = index;
    }
}

fn lookup(scope: &Scope, doc: &mut Doc, prefix: &[u8]) -> Option<i32> {
    if let Some(&id) = scope.prefixes.get(prefix) {
        return Some(id);
    }
    if prefix == b"xml" {
        return Some(doc.xml_ns());
    }
    None
}

fn classify_attr(scope: &Scope, doc: &mut Doc, name_off: usize, name: &[u8]) -> (usize, usize, i32, bool) {
    let Some(colon) = name.iter().position(|&byte| byte == b':') else {
        return (name_off, name.len(), -1, false);
    };
    let prefix = &name[..colon];
    let local_off = name_off + colon + 1;
    let local_len = name.len() - colon - 1;
    if let Some(id) = lookup(scope, doc, prefix) {
        let is_lang = prefix == b"xml" && &name[colon + 1..] == b"lang";
        (local_off, local_len, id, is_lang)
    } else {
        (local_off, local_len, -1, false)
    }
}

fn parse_attrs(bytes: &[u8], mut index: usize, stop: usize) -> Option<Vec<RawAttr>> {
    let mut attrs = Vec::new();
    while index < stop {
        index = skip_ws(bytes, index, stop);
        if index >= stop {
            break;
        }
        let byte = bytes[index];
        if byte == b'/' || !is_name_start(byte) {
            return None;
        }
        let start = index;
        index += 1;
        while index < stop && is_name_byte(bytes[index]) {
            index += 1;
        }
        let name_len = index - start;
        index = skip_ws(bytes, index, stop);
        if index >= stop || bytes[index] != b'=' {
            return None;
        }
        index += 1;
        index = skip_ws(bytes, index, stop);
        if index >= stop || (bytes[index] != b'"' && bytes[index] != b'\'') {
            return None;
        }
        let quote = bytes[index];
        index += 1;
        let value_at = index;
        while index < stop && bytes[index] != quote {
            index += 1;
        }
        if index >= stop || bytes[index] != quote {
            return None;
        }
        let raw = &bytes[value_at..index];
        let value = if raw.contains(&b'&') {
            Bytes::Owned(decode_attr(raw)?)
        } else {
            Bytes::Slice { off: value_at, len: raw.len() }
        };
        attrs.push(RawAttr { name_off: start, name_len, value });
        index += 1;
    }
    Some(attrs)
}

fn end_name(bytes: &[u8], pos: usize, gt: usize) -> Option<&[u8]> {
    let mut index = pos + 2;
    index = skip_ws(bytes, index, gt);
    if index >= gt || !is_name_start(bytes[index]) {
        return None;
    }
    let start = index;
    index += 1;
    while index < gt && is_name_byte(bytes[index]) {
        index += 1;
    }
    let end = index;
    while index < gt {
        if !is_ws(bytes[index]) {
            return None;
        }
        index += 1;
    }
    Some(&bytes[start..end])
}

fn find_gt(bytes: &[u8], pos: usize) -> Option<usize> {
    let mut index = pos + 1;
    while index < bytes.len() {
        match bytes[index] {
            b'"' | b'\'' => {
                let quote = bytes[index];
                index += 1;
                while index < bytes.len() && bytes[index] != quote {
                    index += 1;
                }
                if index >= bytes.len() {
                    return None;
                }
                index += 1;
            }
            b'>' => return Some(index),
            _ => index += 1,
        }
    }
    None
}

fn find_byte(bytes: &[u8], from: usize, needle: u8) -> Option<usize> {
    bytes[from..].iter().position(|&byte| byte == needle).map(|index| from + index)
}

fn skip_ws(bytes: &[u8], mut index: usize, stop: usize) -> usize {
    while index < stop && is_ws(bytes[index]) {
        index += 1;
    }
    index
}

fn is_ws(byte: u8) -> bool {
    byte == b' ' || byte == b'\t' || byte == b'\n' || byte == b'\r'
}

fn is_name_start(byte: u8) -> bool {
    byte.is_ascii_uppercase() || byte.is_ascii_lowercase() || byte == b'_' || byte == b':'
}

fn is_name_byte(byte: u8) -> bool {
    is_name_start(byte) || byte.is_ascii_digit() || byte == b'-' || byte == b'.'
}

fn first_colon(name: &[u8]) -> i32 {
    name.iter().position(|&byte| byte == b':').map(|index| index as i32 + 1).unwrap_or(0)
}

fn line_at(newlines: &[usize], nl_i: &mut usize, pos: usize) -> i32 {
    while *nl_i < newlines.len() && newlines[*nl_i] < pos {
        *nl_i += 1;
    }
    *nl_i as i32 + 1
}

fn entities_ok(chunk: &[u8]) -> bool {
    let mut index = 0;
    while index < chunk.len() {
        if chunk[index] != b'&' {
            index += 1;
            continue;
        }
        let Some(rel) = chunk[index + 1..].iter().position(|&byte| byte == b';') else {
            return false;
        };
        let name = &chunk[index + 1..index + 1 + rel];
        if name.first() == Some(&b'#') {
            if char_ref_code(name).is_none() {
                return false;
            }
        } else if predefined(name).is_none() {
            return false;
        }
        index += rel + 2;
    }
    true
}

fn decode_attr(value: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(value.len());
    let mut index = 0;
    while index < value.len() {
        if value[index] != b'&' {
            let start = index;
            while index < value.len() && value[index] != b'&' {
                index += 1;
            }
            out.extend_from_slice(&value[start..index]);
            continue;
        }
        let Some(rel) = value[index + 1..].iter().position(|&byte| byte == b';') else {
            return None;
        };
        let name = &value[index + 1..index + 1 + rel];
        if let Some(text) = predefined(name) {
            out.extend_from_slice(text);
        } else if name.first() == Some(&b'#') {
            out.extend_from_slice(&codepoint_bytes(char_ref_code(name)?));
        } else {
            return None;
        }
        index += rel + 2;
    }
    Some(out)
}

fn predefined(name: &[u8]) -> Option<&'static [u8]> {
    match name {
        b"lt" => Some(b"<"),
        b"gt" => Some(b">"),
        b"amp" => Some(b"&"),
        b"quot" => Some("\"".as_bytes()),
        b"apos" => Some(b"'"),
        _ => None,
    }
}

fn char_ref_code(name: &[u8]) -> Option<u32> {
    if name.first() != Some(&b'#') {
        return None;
    }
    let hex = name.get(1).copied() == Some(b'x') || name.get(1).copied() == Some(b'X');
    let digits = if hex { name.get(2..)? } else { name.get(1..)? };
    if digits.is_empty() {
        return None;
    }
    let mut code: u64 = 0;
    let base: u64 = if hex { 16 } else { 10 };
    for &byte in digits {
        let digit = match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' if hex => byte - b'a' + 10,
            b'A'..=b'F' if hex => byte - b'A' + 10,
            _ => return None,
        } as u64;
        code = code.checked_mul(base)?.checked_add(digit)?;
        if code > 0x10FFFF {
            return None;
        }
    }
    Some(code as u32)
}

fn codepoint_bytes(code: u32) -> Vec<u8> {
    if code == 0 || (0xD800..=0xDFFF).contains(&code) {
        return vec![0xEF, 0xBF, 0xBD];
    }
    let mut buf = [0u8; 4];
    let text = char::from_u32(code).unwrap_or('\u{FFFD}').encode_utf8(&mut buf);
    text.as_bytes().to_vec()
}

#[cfg_attr(test, allow(dead_code))]
pub fn xml_href() -> &'static [u8] {
    b"http://www.w3.org/XML/1998/namespace"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name<'a>(doc: &Doc, bytes: &'a [u8], index: usize) -> &'a [u8] {
        let off = doc.off[index] as usize;
        let len = doc.len[index] as usize;
        &bytes[off..off + len]
    }

    #[test]
    fn nested_text_and_lines() {
        let bytes = b"\n<a>\n<b>t</b>\n</a>\n";
        let doc = parse(bytes, 0).unwrap();
        assert_eq!(doc.typ, vec![ELEMENT, TEXT, ELEMENT, TEXT, TEXT]);
        assert_eq!(name(&doc, bytes, 0), b"a");
        assert_eq!(name(&doc, bytes, 2), b"b");
        assert_eq!(doc.parent, vec![-1, 0, 0, 2, 0]);
        assert_eq!(doc.child, vec![1, -1, 3, -1, -1]);
        assert_eq!(doc.nex, vec![-1, 2, 4, -1, -1]);
        assert_eq!(doc.line, vec![2, 3, 3, 3, 4]);
        assert_eq!(&bytes[doc.text_off[3] as usize..doc.text_off[3] as usize + doc.text_len[3] as usize], b"t");
        assert_eq!(doc.top_head, 0);
        assert_eq!(doc.top_tail, 0);
    }

    #[test]
    fn empty_and_self_closing() {
        let doc = parse(b"  <a></a> \n <b/>", 0).unwrap();
        assert_eq!(doc.typ, vec![ELEMENT, ELEMENT]);
        assert_eq!(doc.child, vec![-1, -1]);
        assert_eq!(doc.nex, vec![1, -1]);
        assert_eq!(doc.top_head, 0);
        assert_eq!(doc.top_tail, 1);
    }

    #[test]
    fn namespaces_shadow_and_attributes() {
        let bytes = br#"<catalog xmlns="urn:bench" xmlns:ex="urn:extra" xml:lang="en"><item id="0" sku="SKU-0" ex:kind="widget"><name>Item 0 &amp; co</name></item></catalog>"#;
        let doc = parse(bytes, 0).unwrap();
        assert_eq!(doc.ns[0], 0);
        assert_eq!(doc.defs[0], vec![0, 1]);
        assert_eq!(doc.langs[0], Some(0));
        assert_eq!(doc.xml_builtin, Some(2));
        assert!(matches!(doc.prefixes[0], Prefix::None));
        assert!(matches!(doc.prefixes[2], Prefix::Xml));
        assert_eq!(doc.attrs[0][0].ns, 2);
        assert_eq!(doc.attrs[0][0].name_len, 4);
        let item = doc.child[0] as usize;
        assert_eq!(name(&doc, bytes, item), b"item");
        assert_eq!(doc.ns[item], 0);
        assert_eq!(doc.attrs[item].len(), 3);
        assert_eq!(doc.attrs[item][2].ns, 1);
        let kind = &doc.attrs[item][2];
        let kind_name = &bytes[kind.name_off..kind.name_off + kind.name_len];
        assert_eq!(kind_name, b"kind");
        let name_i = doc.child[item] as usize;
        let text_i = doc.child[name_i] as usize;
        let text = &bytes[doc.text_off[text_i] as usize..doc.text_off[text_i] as usize + doc.text_len[text_i] as usize];
        assert_eq!(text, b"Item 0 &amp; co");
    }

    #[test]
    fn default_namespace_restores_after_child() {
        let bytes = br#"<a xmlns="urn:1"><b xmlns="urn:2"><c/></b><d/></a>"#;
        let doc = parse(bytes, 0).unwrap();
        assert_eq!(doc.ns[0], 0);
        assert_eq!(doc.ns[1], 1);
        assert_eq!(doc.ns[2], 1);
        assert_eq!(name(&doc, bytes, 3), b"d");
        assert_eq!(doc.ns[3], 0);
    }

    #[test]
    fn self_closing_namespace_does_not_leak() {
        let bytes = br#"<a xmlns="urn:1"><b xmlns="urn:2"/><c/></a>"#;
        let doc = parse(bytes, 0).unwrap();
        assert_eq!(doc.ns[1], 1);
        assert_eq!(name(&doc, bytes, 2), b"c");
        assert_eq!(doc.ns[2], 0);
        assert_eq!(doc.child[1], -1);
    }

    #[test]
    fn unbound_prefix_is_not_the_default_namespace() {
        let bytes = br#"<a xmlns="urn:1"><nope:b foo:bar="1"/></a>"#;
        let doc = parse(bytes, 0).unwrap();
        assert_eq!(name(&doc, bytes, 1), b"nope:b");
        assert_eq!(doc.local[1], 0);
        assert_eq!(doc.ns[1], -1);
        assert_eq!(doc.attrs[1][0].ns, -1);
        let attr = &doc.attrs[1][0];
        assert_eq!(&bytes[attr.name_off..attr.name_off + attr.name_len], b"bar");
    }

    #[test]
    fn decodes_attribute_entities_and_keeps_text_offsets() {
        let bytes = br#"<a b="&amp;&#39;&#x41;&#X42;&#0;">&lt;</a>"#;
        let doc = parse(bytes, 0).unwrap();
        match &doc.attrs[0][0].value {
            Bytes::Owned(value) => {
                assert_eq!(value, b"&'AB\xef\xbf\xbd");
            }
            other => panic!("decoded attr, got {other:?}"),
        }
        let text = doc.child[0] as usize;
        let raw = &bytes[doc.text_off[text] as usize..doc.text_off[text] as usize + doc.text_len[text] as usize];
        assert_eq!(raw, b"&lt;");
    }

    #[test]
    fn rejects_constructs_the_ruby_reader_owns() {
        assert!(parse(b"<a>&foo;</a>", 0).is_none());
        assert!(parse(b"<a b='&foo;'></a>", 0).is_none());
        assert!(parse(b"<a></b>", 0).is_none());
        assert!(parse(b"<a>", 0).is_none());
        assert!(parse(b"<a><!-- --></a>", 0).is_none());
        assert!(parse(b"<a><?pi?></a>", 0).is_none());
        assert!(parse(b"<!DOCTYPE a><a/>", 0).is_none());
        assert!(parse(b"<a/> x", 0).is_none());
        assert!(parse(b"<a b=c></a>", 0).is_none());
        assert!(parse(br#"<a xmlns:=""></a>"#, 0).is_none());
    }

    #[test]
    fn ignores_a_declaration_before_origin() {
        let bytes = b"<?xml version=\"1.0\"?>\n<a/>";
        let origin = bytes.iter().position(|&byte| byte == b'\n').unwrap();
        let doc = parse(bytes, origin).unwrap();
        assert_eq!(doc.typ.len(), 1);
        assert_eq!(doc.line[0], 2);
    }
}
