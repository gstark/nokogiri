//! Parse with xmloxide and copy the tree into the Ruby document store.
//!
//! The store stays the live DOM. xmloxide does not model namespace nodes,
//! attribute nodes, or DTD declarations as separate tree nodes, and the Ruby
//! API does.

use std::cell::RefCell;
use std::rc::Rc;

use xmloxide::error::{ErrorSeverity, ParseDiagnostic, ParseError as OxideParseError};
use xmloxide::html::{HtmlParseOptions, parse_html_with_options};
use xmloxide::parser::{ParseOptions, parse_str_with_options};
use xmloxide::tree::{Attribute, Document, NodeId, NodeKind};

use crate::parse::{NOBLANKS, NOCDATA, NOENT, ParseError, Parsed, RECOVER};
use crate::store::{
    Store, ATTRIBUTE, CDATA, COMMENT, DTD, ELEMENT, ENTITY_REF, PI, TEXT, XML_NS,
};

const HTML_NOIMPLIED: i32 = 1 << 13;

pub fn import(
    input: &str,
    url: Option<String>,
    encoding: Option<String>,
    options: i32,
    key: u64,
    html: bool,
) -> Parsed {
    let recover = options & RECOVER != 0;
    let parsed = if html {
        let opts = HtmlParseOptions::default()
            .recover(recover)
            .no_blanks(options & NOBLANKS != 0)
            .no_implied(options & HTML_NOIMPLIED != 0);
        parse_html_with_options(input, &opts)
    } else {
        let opts = ParseOptions::default()
            .recover(recover)
            .no_blanks(options & NOBLANKS != 0);
        parse_str_with_options(input, &opts)
    };

    match parsed {
        Ok(doc) => document_to_store(doc, url, encoding, options, key, html),
        Err(error) => {
            let errors = errors_from_failure(&error);
            let store = Store::new_document(html, key);
            apply_document_fields(&store, &url, &encoding, html, None, None);
            Parsed { store, errors }
        }
    }
}

fn document_to_store(
    mut doc: Document,
    url: Option<String>,
    encoding: Option<String>,
    options: i32,
    key: u64,
    html: bool,
) -> Parsed {
    let mut errors = Vec::new();
    for diagnostic in &doc.diagnostics {
        errors.push(convert_diagnostic(diagnostic));
    }
    let store = Store::new_document(html, key);
    apply_document_fields(&store, &url, &encoding, html, doc.version.as_deref(), doc.encoding.as_deref());
    {
        let mut store_ref = store.borrow_mut();
        store_ref.reserve_nodes(doc.node_count());
        let root = doc.root();
        import_children(&mut doc, &mut store_ref, root, 0, html, options);
    }
    Parsed { store, errors }
}

fn apply_document_fields(
    store: &Rc<RefCell<Store>>,
    url: &Option<String>,
    encoding: &Option<String>,
    html: bool,
    version: Option<&str>,
    declared_encoding: Option<&str>,
) {
    let mut store_ref = store.borrow_mut();
    if html {
        store_ref.nodes[0].version.clear();
        store_ref.nodes[0].encoding = Some("UTF-8".to_string());
    }
    if let Some(url) = url {
        store_ref.nodes[0].url = Some(url.clone());
    }
    if let Some(encoding) = encoding {
        if !encoding.is_empty() {
            store_ref.nodes[0].encoding = Some(encoding.clone());
        }
    }
    if !html {
        if let Some(version) = version {
            if !version.is_empty() {
                store_ref.nodes[0].version = version.to_string();
            }
        }
        if let Some(encoding) = declared_encoding {
            if !encoding.is_empty() {
                store_ref.nodes[0].encoding = Some(encoding.to_string());
            }
        }
    }
}

fn import_children(doc: &mut Document, store: &mut Store, oxide_parent: NodeId, parent: u32, html: bool, options: i32) {
    let mut child = doc.first_child(oxide_parent);
    while let Some(id) = child {
        let next = doc.next_sibling(id);
        import_node(doc, store, id, parent, html, options);
        child = next;
    }
}

fn import_node(doc: &mut Document, store: &mut Store, id: NodeId, parent: u32, html: bool, options: i32) {
    let line = source_line(doc, id);
    let kind = doc.take_kind(id);
    match kind {
        NodeKind::Document => {
            import_children(doc, store, id, parent, html, options);
        }
        NodeKind::Element { name, prefix, namespace, attributes } => {
            import_element(doc, store, id, parent, html, options, name, prefix, namespace, attributes, line);
        }
        NodeKind::Text { content } => {
            if skip_text(&content, options) {
                return;
            }
            add_text_at(store, parent, content, line);
        }
        NodeKind::CData { content } => {
            if options & NOCDATA != 0 {
                if !skip_text(&content, options) {
                    add_text_at(store, parent, content, line);
                }
                return;
            }
            let node = store.alloc(CDATA, 0);
            store.nodes[node as usize].content = content;
            store.nodes[node as usize].line = line;
            store.append_child(parent, node);
        }
        NodeKind::Comment { content } => {
            let node = store.alloc(COMMENT, 0);
            store.nodes[node as usize].content = content;
            store.nodes[node as usize].line = line;
            store.append_child(parent, node);
        }
        NodeKind::ProcessingInstruction { target, data } => {
            let node = store.alloc(PI, 0);
            store.nodes[node as usize].name = Some(target);
            store.nodes[node as usize].content = data.unwrap_or_default();
            store.nodes[node as usize].line = line;
            store.append_child(parent, node);
        }
        NodeKind::EntityRef { name, value } => {
            if options & NOENT != 0 {
                if doc.first_child(id).is_none() {
                    if let Some(value) = value {
                        if !value.is_empty() {
                            add_text_at(store, parent, value, line);
                        }
                    }
                    return;
                }
                import_children(doc, store, id, parent, html, options);
                return;
            }
            let node = store.alloc(ENTITY_REF, 0);
            store.nodes[node as usize].name = Some(name);
            store.nodes[node as usize].content = value.unwrap_or_default();
            store.nodes[node as usize].line = line;
            store.append_child(parent, node);
        }
        NodeKind::DocumentType { name, system_id, public_id, internal_subset } => {
            let node = store.alloc(DTD, 0);
            let dtd_name = owned_html_name(html, name);
            store.nodes[node as usize].name = Some(if dtd_name.is_empty() { "html".to_string() } else { dtd_name });
            store.nodes[node as usize].line = line;
            store.nodes[node as usize].external_id = public_id;
            store.nodes[node as usize].system_id = system_id;
            if let Some(subset) = internal_subset {
                store.nodes[node as usize].content = subset;
            }
            store.append_child(parent, node);
            if parent == 0 {
                store.nodes[0].internal_subset = Some(node);
            }
        }
    }
}

fn import_element(
    doc: &mut Document,
    store: &mut Store,
    id: NodeId,
    parent: u32,
    html: bool,
    options: i32,
    name: String,
    prefix: Option<String>,
    namespace: Option<String>,
    attributes: Vec<Attribute>,
    line: i64,
) {
    let local = owned_html_name(html, name);
    let node = store.alloc(ELEMENT, 0);
    store.nodes[node as usize].line = line;
    store.append_child(parent, node);

    if html {
        // HTML4 keeps xmlns as an attribute and does not bind a namespace.
        for attr in attributes {
            import_attribute(store, node, true, attr);
        }
    } else {
        let mut regular = Vec::new();
        for attr in attributes {
            if is_xmlns(&attr) {
                let decl_prefix = if attr.prefix.as_deref() == Some("xmlns") {
                    if attr.name.is_empty() { None } else { Some(attr.name) }
                } else {
                    None
                };
                define_ns(store, node, decl_prefix, attr.value);
            } else {
                regular.push(attr);
            }
        }
        for attr in regular {
            import_attribute(store, node, false, attr);
        }
        bind_ns(store, node, prefix.as_deref(), namespace.as_deref(), &local);
    }
    if store.nodes[node as usize].name.is_none() {
        store.nodes[node as usize].name = Some(shown_name(html, local, prefix.as_deref()));
    }
    import_children(doc, store, id, node, html, options);
}

fn import_attribute(store: &mut Store, element: u32, html: bool, attr: Attribute) {
    let local = owned_html_name(html, attr.name);
    let prefix = attr.prefix;
    let node = store.alloc(ATTRIBUTE, 0);
    store.nodes[node as usize].content = attr.value;
    store.append_child(element, node);
    // An unprefixed attribute is not in the default namespace.
    if !html && prefix.is_some() {
        bind_ns(store, node, prefix.as_deref(), attr.namespace.as_deref(), &local);
    }
    if store.nodes[node as usize].name.is_none() {
        store.nodes[node as usize].name = Some(shown_name(html, local, prefix.as_deref()));
    }
}

fn owned_html_name(html: bool, name: String) -> String {
    if html && name.bytes().any(|byte| byte.is_ascii_uppercase()) {
        name.to_ascii_lowercase()
    } else {
        name
    }
}

fn shown_name(html: bool, local: String, prefix: Option<&str>) -> String {
    if html {
        if let Some(prefix) = prefix {
            if !prefix.is_empty() {
                let prefix = owned_html_name(true, prefix.to_string());
                return format!("{prefix}:{local}");
            }
        }
    }
    local
}

fn is_xmlns(attr: &Attribute) -> bool {
    attr.prefix.as_deref() == Some("xmlns") || (attr.prefix.is_none() && attr.name == "xmlns")
}

fn define_ns(store: &mut Store, element: u32, prefix: Option<String>, href: String) -> u32 {
    if prefix.as_deref() == Some("xml") && href == XML_NS {
        let id = store.ensure_xml_ns();
        if !store.nodes[element as usize].ns_defs.contains(&id) {
            store.nodes[element as usize].ns_defs.push(id);
        }
        return id;
    }
    let id = store.add_ns(prefix, href);
    store.nodes[element as usize].ns_defs.push(id);
    id
}

fn bind_ns(store: &mut Store, id: u32, prefix: Option<&str>, namespace: Option<&str>, local: &str) {
    if prefix == Some("xmlns") {
        return;
    }
    if prefix == Some("xml") {
        let ns = store.ensure_xml_ns();
        store.nodes[id as usize].ns = Some(ns);
        return;
    }
    if let Some(found) = store.lookup_ns(id, prefix) {
        let href_matches = namespace.is_none_or(|uri| store.nss[found as usize].href == uri);
        if href_matches {
            store.nodes[id as usize].ns = Some(found);
            return;
        }
    }
    if let Some(uri) = namespace {
        if !uri.is_empty() {
            let ns = store.add_ns(prefix.map(str::to_string), uri.to_string());
            store.nodes[id as usize].ns = Some(ns);
            return;
        }
    }
    if let Some(prefix) = prefix {
        if !prefix.is_empty() {
            store.nodes[id as usize].name = Some(format!("{prefix}:{local}"));
        }
    }
}

fn source_line(doc: &Document, id: NodeId) -> i64 {
    i64::from(doc.source_line(id))
}

fn add_text_at(store: &mut Store, parent: u32, content: String, line: i64) {
    let previous = store.nodes[parent as usize].children.last().copied();
    add_text(store, parent, content);
    if let Some(last) = store.nodes[parent as usize].children.last().copied() {
        if Some(last) != previous {
            store.nodes[last as usize].line = line;
        }
    }
}

fn add_text(store: &mut Store, parent: u32, content: String) {
    if content.is_empty() {
        return;
    }
    if let Some(last) = store.nodes[parent as usize].children.last().copied() {
        if store.nodes[last as usize].kind == TEXT {
            store.nodes[last as usize].content.push_str(&content);
            return;
        }
    }
    let node = store.alloc(TEXT, 0);
    store.nodes[node as usize].content = content;
    store.append_child(parent, node);
}

fn skip_text(content: &str, options: i32) -> bool {
    options & NOBLANKS != 0 && content.bytes().all(|byte| matches!(byte, b' ' | b'\t' | b'\n' | b'\r'))
}

fn errors_from_failure(error: &OxideParseError) -> Vec<ParseError> {
    let mut errors: Vec<ParseError> = error.diagnostics.iter().map(convert_diagnostic).collect();
    let primary = ParseError {
        message: suite_message(&error.message),
        line: i64::from(error.location.line),
        column: i64::from(error.location.column),
        level: 3,
        domain: 1,
        code: 77,
    };
    if errors.last().is_none_or(|item| item.message != primary.message) {
        errors.push(primary);
    }
    errors
}

fn convert_diagnostic(diagnostic: &ParseDiagnostic) -> ParseError {
    let level = match diagnostic.severity {
        ErrorSeverity::Warning => 1,
        ErrorSeverity::Error => 2,
        ErrorSeverity::Fatal => 3,
    };
    ParseError {
        message: suite_message(&diagnostic.message),
        line: i64::from(diagnostic.location.line),
        column: i64::from(diagnostic.location.column),
        level,
        domain: 1,
        code: if level >= 3 { 77 } else { 1 },
    }
}

/// The non-libxml suite checks a few parser sentences exactly.
fn suite_message(message: &str) -> String {
    if let Some(rest) = message.strip_prefix("mismatched end tag: expected </") {
        if let Some(name) = rest.split('>').next() {
            if !name.is_empty() && !name.contains('<') && !name.contains(' ') {
                return format!(
                    "The element type \"{name}\" must be terminated by the matching end-tag \"</{name}>\"."
                );
            }
        }
    }
    message.to_string()
}
