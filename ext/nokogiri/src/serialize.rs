//! Serializers for XML and HTML.

use crate::store::{
    Notation, Store, ATTRIBUTE, ATTRIBUTE_DECL, CDATA, COMMENT, DTD, DOCUMENT, DOCUMENT_FRAG, ELEMENT,
    ELEMENT_DECL, ENTITY_DECL, ENTITY_REF, HTML_DOCUMENT, PI, TEXT,
};

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

pub const FORMAT: i32 = 1;
pub const NO_DECLARATION: i32 = 2;
pub const NO_EMPTY_TAGS: i32 = 4;
pub const AS_XHTML: i32 = 16;
pub const AS_XML: i32 = 32;
pub const AS_HTML: i32 = 64;

pub fn write_node(store: &Store, id: u32, encoding: Option<&str>, indent: &str, options: i32) -> String {
    let mut out = String::new();
    let kind = store.nodes[id as usize].kind;
    let as_html = options & AS_HTML != 0 || (store.html && options & AS_XML == 0 && options & AS_XHTML == 0 && kind != DOCUMENT);
    let html = as_html || (store.html && options & AS_XML == 0 && matches!(kind, HTML_DOCUMENT | DOCUMENT_FRAG));
    if matches!(kind, DOCUMENT | HTML_DOCUMENT) && !html && options & NO_DECLARATION == 0 {
        let version = if store.nodes[id as usize].version.is_empty() {
            "1.0"
        } else {
            store.nodes[id as usize].version.as_str()
        };
        out.push_str("<?xml version=\"");
        out.push_str(version);
        out.push('"');
        let enc = encoding.or(store.nodes[id as usize].encoding.as_deref());
        if let Some(enc) = enc {
            if !enc.is_empty() {
                out.push_str(" encoding=\"");
                out.push_str(enc);
                out.push('"');
            }
        }
        out.push_str("?>\n");
    }
    write_one(store, id, &mut out, html, options, indent, 0, true);
    if matches!(kind, DOCUMENT | HTML_DOCUMENT) && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn write_one(
    store: &Store,
    id: u32,
    out: &mut String,
    html: bool,
    options: i32,
    indent: &str,
    depth: usize,
    root_call: bool,
) {
    let node = &store.nodes[id as usize];
    match node.kind {
        DOCUMENT | HTML_DOCUMENT | DOCUMENT_FRAG => {
            for (index, child) in node.children.clone().into_iter().enumerate() {
                if index > 0 && !html && options & FORMAT != 0 {
                    out.push('\n');
                }
                write_one(store, child, out, html, options, indent, 0, false);
            }
        }
        ELEMENT => write_element(store, id, out, html, options, indent, depth, root_call),
        TEXT => {
            if html && parent_is_raw(store, id) {
                out.push_str(&node.content);
            } else {
                push_escaped(out, &node.content, false, html);
            }
        }
        CDATA => {
            out.push_str("<![CDATA[");
            out.push_str(&node.content);
            out.push_str("]]>");
        }
        COMMENT => {
            out.push_str("<!--");
            out.push_str(&node.content);
            out.push_str("-->");
        }
        PI => {
            out.push_str("<?");
            if let Some(name) = &node.name {
                out.push_str(name);
            }
            if !node.content.is_empty() {
                out.push(' ');
                out.push_str(&node.content);
            }
            out.push_str("?>");
        }
        DTD => {
            if html {
                write_html_doctype(store, id, out);
            } else {
                write_xml_doctype(store, id, out);
            }
        }
        ENTITY_REF => {
            out.push('&');
            if let Some(name) = &node.name {
                out.push_str(name);
            }
            out.push(';');
        }
        ENTITY_DECL => write_entity_decl(store, id, out),
        ELEMENT_DECL => write_element_decl(store, id, out),
        ATTRIBUTE_DECL => write_attribute_decl(store, id, out),
        ATTRIBUTE => write_attribute(store, id, out, html),
        _ => {}
    }
}

fn write_element(
    store: &Store,
    id: u32,
    out: &mut String,
    html: bool,
    options: i32,
    indent: &str,
    depth: usize,
    _root_call: bool,
) {
    let name = element_name(store, id, html);
    out.push('<');
    out.push_str(&name);
    write_namespace_decls(store, id, out);
    let attrs = store.nodes[id as usize].attrs.clone();
    for attr in attrs {
        out.push(' ');
        write_attribute(store, attr, out, html);
    }
    let children = store.nodes[id as usize].children.clone();
    let empty = children.is_empty();
    let void = html && is_void(&name);
    if empty && !html && options & NO_EMPTY_TAGS == 0 {
        out.push_str("/>");
        return;
    }
    if void {
        out.push('>');
        return;
    }
    out.push('>');
    let format = options & FORMAT != 0;
    let inline = children.iter().any(|child| {
        matches!(store.nodes[*child as usize].kind, TEXT | CDATA | ENTITY_REF)
    });
    let break_html = html && format && html_breaks(&name) && !inline && !children.is_empty();
    let break_xml = !html && format && !inline && !children.is_empty();
    if break_html {
        out.push('\n');
    }
    for child in &children {
        if break_xml {
            out.push('\n');
            push_indent(out, indent, depth + 1);
        }
        write_one(store, *child, out, html, options, indent, depth + 1, false);
        if break_html && store.nodes[*child as usize].kind == ELEMENT && html_block(store.nodes[*child as usize].name.as_deref().unwrap_or("")) {
            out.push('\n');
        }
    }
    if break_xml {
        out.push('\n');
        push_indent(out, indent, depth);
    } else if break_html {
        let last_block = children.last().is_some_and(|child| {
            store.nodes[*child as usize].kind == ELEMENT
                && html_block(store.nodes[*child as usize].name.as_deref().unwrap_or(""))
        });
        if !last_block {
            out.push('\n');
        }
    }
    out.push_str("</");
    out.push_str(&name);
    out.push('>');
}

fn element_name(store: &Store, id: u32, _html: bool) -> String {
    store.qualified_name(id)
}

fn write_namespace_decls(store: &Store, id: u32, out: &mut String) {
    let defs = store.nodes[id as usize].ns_defs.clone();
    for def in defs {
        let ns = &store.nss[def as usize];
        if ns.prefix.as_deref() == Some("xml") {
            continue;
        }
        out.push(' ');
        match &ns.prefix {
            Some(prefix) if !prefix.is_empty() => {
                out.push_str("xmlns:");
                out.push_str(prefix);
            }
            _ => out.push_str("xmlns"),
        }
        out.push_str("=\"");
        push_escaped(out, &ns.href, true, false);
        out.push('"');
    }
    if let Some(ns_id) = store.nodes[id as usize].ns {
        let in_scope = ancestor_has_ns(store, id, ns_id);
        if !in_scope {
            let ns = &store.nss[ns_id as usize];
            if ns.prefix.as_deref() != Some("xml") {
                let already = store.nodes[id as usize].ns_defs.contains(&ns_id);
                if !already {
                    out.push(' ');
                    match &ns.prefix {
                        Some(prefix) if !prefix.is_empty() => {
                            out.push_str("xmlns:");
                            out.push_str(prefix);
                        }
                        _ => out.push_str("xmlns"),
                    }
                    out.push_str("=\"");
                    push_escaped(out, &ns.href, true, false);
                    out.push('"');
                }
            }
        }
    }
}

fn ancestor_has_ns(store: &Store, id: u32, ns_id: u32) -> bool {
    let ns = &store.nss[ns_id as usize];
    let mut node = store.nodes[id as usize].parent;
    while let Some(current) = node {
        for def in &store.nodes[current as usize].ns_defs {
            let other = &store.nss[*def as usize];
            if other.prefix == ns.prefix && other.href == ns.href {
                return true;
            }
        }
        node = store.nodes[current as usize].parent;
    }
    false
}

fn write_attribute(store: &Store, id: u32, out: &mut String, html: bool) {
    let name = store.qualified_name(id);
    let local = store.nodes[id as usize].name.clone().unwrap_or_default();
    let mut value = store.nodes[id as usize].content.clone();
    if html && (value == name || (value.is_empty() && html_boolean_attr(&local))) {
        out.push_str(&name);
        return;
    }
    if html && html_uri_attr(&local) {
        value = value.replace('"', "%22");
    }
    out.push_str(&name);
    out.push_str("=\"");
    push_escaped(out, &value, true, html);
    out.push('"');
}

fn html_boolean_attr(name: &str) -> bool {
    matches!(
        name,
        "checked" | "compact" | "declare" | "defer" | "disabled" | "ismap" | "multiple" | "nohref"
            | "noresize" | "noshade" | "nowrap" | "readonly" | "selected" | "async" | "autofocus"
            | "autoplay" | "controls" | "default" | "hidden" | "loop" | "open" | "required"
            | "reversed" | "scoped" | "muted"
    )
}

fn html_uri_attr(name: &str) -> bool {
    matches!(
        name,
        "href" | "src" | "action" | "name" | "cite" | "background" | "longdesc" | "usemap" | "profile"
            | "codebase" | "classid" | "data" | "formaction" | "poster" | "manifest" | "archive"
    )
}

fn write_xml_doctype(store: &Store, id: u32, out: &mut String) {
    let name = store.nodes[id as usize].name.clone().unwrap_or_default();
    let external_id = store.nodes[id as usize].external_id.clone();
    let system_id = store.nodes[id as usize].system_id.clone();
    let children = store.nodes[id as usize].children.clone();
    let notes: Vec<Notation> = store.notations.iter().filter(|note| note.dtd == id).cloned().collect();
    out.push_str("<!DOCTYPE ");
    out.push_str(&name);
    if let Some(external) = &external_id {
        out.push_str(" PUBLIC \"");
        out.push_str(external);
        out.push('"');
        if let Some(system) = &system_id {
            out.push(' ');
            out.push('"');
            out.push_str(system);
            out.push('"');
        }
    } else if let Some(system) = &system_id {
        out.push_str(" SYSTEM \"");
        out.push_str(system);
        out.push('"');
    }
    if !children.is_empty() || !notes.is_empty() {
        out.push_str(" [\n");
        for note in &notes {
            write_notation(note, out);
        }
        for child in children {
            write_declaration(store, child, out);
        }
        out.push(']');
    }
    out.push('>');
}

fn write_declaration(store: &Store, id: u32, out: &mut String) {
    match store.nodes[id as usize].kind {
        ENTITY_DECL => write_entity_decl(store, id, out),
        ELEMENT_DECL => write_element_decl(store, id, out),
        ATTRIBUTE_DECL => write_attribute_decl(store, id, out),
        _ => {}
    }
}

fn write_entity_decl(store: &Store, id: u32, out: &mut String) {
    let node = &store.nodes[id as usize];
    let name = node.name.clone().unwrap_or_default();
    let entity_type = node.entity_type;
    let content = node.content.clone();
    let external_id = node.external_id.clone();
    let system_id = node.system_id.clone();
    out.push_str("<!ENTITY ");
    out.push_str(&name);
    out.push(' ');
    if entity_type == 1 {
        out.push('"');
        out.push_str(&content);
        out.push('"');
    } else if let Some(external) = &external_id {
        out.push_str("PUBLIC \"");
        out.push_str(external);
        out.push('"');
        if let Some(system) = &system_id {
            out.push_str(" \"");
            out.push_str(system);
            out.push('"');
        }
    } else if let Some(system) = &system_id {
        out.push_str("SYSTEM \"");
        out.push_str(system);
        out.push('"');
    }
    if entity_type == 3 {
        out.push_str(" NDATA ");
        out.push_str(&content);
    }
    out.push_str(">\n");
}

fn write_element_decl(store: &Store, id: u32, out: &mut String) {
    let name = store.nodes[id as usize].name.clone().unwrap_or_default();
    let decl = store.decls.get(&id).cloned();
    out.push_str("<!ELEMENT ");
    if let Some(prefix) = decl.as_ref().and_then(|item| item.prefix.clone()) {
        out.push_str(&prefix);
        out.push(':');
    }
    out.push_str(&name);
    out.push(' ');
    match decl.as_ref().map(|item| item.element_type) {
        Some(ELEM_ANY) => out.push_str("ANY"),
        Some(ELEM_EMPTY) | None => out.push_str("EMPTY"),
        _ => {
            if let Some(content) = decl.as_ref().and_then(|item| item.content_id) {
                write_content(store, content, out, true);
            }
        }
    }
    out.push_str(">\n");
}

fn write_attribute_decl(store: &Store, id: u32, out: &mut String) {
    let name = store.nodes[id as usize].name.clone().unwrap_or_default();
    let Some(decl) = store.decls.get(&id).cloned() else {
        return;
    };
    out.push_str("<!ATTLIST ");
    out.push_str(decl.elem_name.as_deref().unwrap_or(""));
    out.push(' ');
    out.push_str(&name);
    out.push(' ');
    if decl.attr_enum.is_empty() {
        out.push_str(&decl.attr_type);
    } else {
        out.push('(');
        out.push_str(&decl.attr_enum.join(" | "));
        out.push(')');
    }
    if let Some(kind) = &decl.attr_default_kind {
        out.push_str(" #");
        out.push_str(kind);
    }
    if let Some(default) = &decl.attr_default {
        out.push_str(" \"");
        out.push_str(default);
        out.push('"');
    }
    out.push_str(">\n");
}

fn write_notation(note: &Notation, out: &mut String) {
    out.push_str("<!NOTATION ");
    out.push_str(&note.name);
    out.push(' ');
    if let Some(public_id) = &note.public_id {
        out.push_str("PUBLIC \"");
        out.push_str(public_id);
        out.push('"');
        if let Some(system_id) = &note.system_id {
            out.push_str(" \"");
            out.push_str(system_id);
            out.push('"');
        }
    } else if let Some(system_id) = &note.system_id {
        out.push_str("SYSTEM \"");
        out.push_str(system_id);
        out.push('"');
    }
    out.push_str(" >\n");
}

fn write_content(store: &Store, id: u32, out: &mut String, glob: bool) {
    let node = store.contents.get(id as usize).cloned();
    let Some(node) = node else {
        return;
    };
    if glob {
        out.push('(');
    }
    match node.kind {
        CONTENT_PCDATA => out.push_str("#PCDATA"),
        CONTENT_ELEMENT => {
            if let Some(prefix) = &node.prefix {
                out.push_str(prefix);
                out.push(':');
            }
            if let Some(name) = &node.name {
                out.push_str(name);
            }
        }
        CONTENT_SEQ | CONTENT_OR => {
            let sep = if node.kind == CONTENT_SEQ { " , " } else { " | " };
            if let Some(left) = node.c1 {
                let child_kind = store.contents.get(left as usize).map(|child| child.kind).unwrap_or(0);
                let child_glob = child_kind == CONTENT_SEQ || child_kind == CONTENT_OR;
                write_content(store, left, out, child_glob);
            }
            out.push_str(sep);
            if let Some(right) = node.c2 {
                let (child_kind, child_occur) = store
                    .contents
                    .get(right as usize)
                    .map(|child| (child.kind, child.occur))
                    .unwrap_or((0, OCCUR_ONCE));
                let child_glob = if node.kind == CONTENT_SEQ {
                    child_kind == CONTENT_OR || (child_kind == CONTENT_SEQ && child_occur != OCCUR_ONCE)
                } else {
                    child_kind == CONTENT_SEQ || (child_kind == CONTENT_OR && child_occur != OCCUR_ONCE)
                };
                write_content(store, right, out, child_glob);
            }
        }
        _ => {}
    }
    if glob {
        out.push(')');
    }
    match node.occur {
        OCCUR_OPT => out.push('?'),
        OCCUR_MULT => out.push('*'),
        OCCUR_PLUS => out.push('+'),
        _ => {}
    }
}

fn write_html_doctype(store: &Store, id: u32, out: &mut String) {
    let node = &store.nodes[id as usize];
    out.push_str("<!DOCTYPE ");
    out.push_str(node.name.as_deref().unwrap_or("html"));
    if let Some(external) = &node.external_id {
        out.push_str(" PUBLIC \"");
        out.push_str(external);
        out.push('"');
        if let Some(system) = &node.system_id {
            out.push_str(" \"");
            out.push_str(system);
            out.push('"');
        }
    } else if let Some(system) = &node.system_id {
        out.push_str(" SYSTEM \"");
        out.push_str(system);
        out.push('"');
    }
    out.push('>');
    out.push('\n');
}

fn push_indent(out: &mut String, indent: &str, depth: usize) {
    for _ in 0..depth {
        out.push_str(indent);
    }
}

fn push_escaped(out: &mut String, text: &str, attr: bool, html: bool) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' if !attr || html => out.push_str("&gt;"),
            '"' if attr => out.push_str("&quot;"),
            '\r' => out.push_str("&#13;"),
            c => out.push(c),
        }
        let _ = html;
    }
}

fn parent_is_raw(store: &Store, id: u32) -> bool {
    let Some(parent) = store.nodes[id as usize].parent else {
        return false;
    };
    matches!(
        store.nodes[parent as usize].name.as_deref(),
        Some("script" | "style" | "xmp" | "iframe" | "noembed" | "noframes" | "noscript" | "plaintext")
    )
}

fn is_void(name: &str) -> bool {
    matches!(
        name,
        "area" | "base" | "basefont" | "bgsound" | "br" | "col" | "embed" | "frame" | "hr"
            | "img" | "input" | "keygen" | "link" | "meta" | "param" | "source" | "track" | "wbr"
            | "isindex"
    )
}

fn html_breaks(name: &str) -> bool {
    matches!(
        name,
        "html" | "head" | "body" | "div" | "ul" | "ol" | "li" | "dl" | "dt" | "dd" | "table"
            | "tr" | "td" | "th" | "form" | "blockquote" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
    )
}

fn html_block(name: &str) -> bool {
    html_breaks(name) || matches!(name, "p" | "pre" | "address" | "center")
}

pub fn html_standard(store: &Store, id: u32, preserve_newline: bool) -> String {
    let mut out = String::new();
    html_standard_one(store, id, &mut out, preserve_newline);
    out
}

fn html_standard_one(store: &Store, id: u32, out: &mut String, preserve_newline: bool) {
    let node = &store.nodes[id as usize];
    match node.kind {
        ELEMENT => {
            let name = store.local_name(id);
            out.push('<');
            out.push_str(&name);
            for attr in node.attrs.clone() {
                out.push(' ');
                let attr_name = store.local_name(attr);
                let value = store.nodes[attr as usize].content.clone();
                out.push_str(&attr_name);
                out.push_str("=\"");
                push_escaped(out, &value, true, true);
                out.push('"');
            }
            out.push('>');
            if !is_void(&name) {
                if preserve_newline && name_is(&name, &["pre", "textarea", "listing"]) {
                    if node.children.first().is_some_and(|child| {
                        store.nodes[*child as usize].kind == TEXT
                            && store.nodes[*child as usize].content.starts_with('\n')
                    }) {
                        out.push('\n');
                    }
                }
                for child in node.children.clone() {
                    html_standard_one(store, child, out, preserve_newline);
                }
                out.push_str("</");
                out.push_str(&name);
                out.push('>');
            }
        }
        TEXT => {
            if parent_is_raw(store, id) {
                out.push_str(&node.content);
            } else {
                push_escaped(out, &node.content, false, true);
            }
        }
        CDATA => out.push_str(&node.content),
        COMMENT => {
            out.push_str("<!--");
            out.push_str(&node.content);
            out.push_str("-->");
        }
        DTD => {
            out.push_str("<!DOCTYPE ");
            out.push_str(node.name.as_deref().unwrap_or("html"));
            out.push('>');
        }
        DOCUMENT | HTML_DOCUMENT | DOCUMENT_FRAG => {
            for child in node.children.clone() {
                html_standard_one(store, child, out, preserve_newline);
            }
        }
        _ => {}
    }
}

fn name_is(name: &str, names: &[&str]) -> bool {
    names.iter().any(|candidate| *candidate == name)
}

pub fn escape_text(text: &str) -> String {
    let bytes = text.as_bytes();
    if bytes.iter().all(|byte| !matches!(byte, b'&' | b'<' | b'>' | b'\r')) {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\r' => out.push_str("&#13;"),
            c => out.push(c),
        }
    }
    out
}
