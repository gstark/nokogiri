//! Schema, canonicalization, and XInclude. The Minitest suite is the spec.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use magnus::error::Error;
use magnus::exception::Exception;
use magnus::{RArray, RClass, Ruby, TryConvert, TypedData, Value, prelude::*};
use magnus::typed_data::DataTypeFunctions;

use xmloxide::serial::c14n::{C14nOptions, canonicalize as c14n_document};
use xmloxide::tree::Document;
use xmloxide::validation::relaxng::{self, RelaxNgSchema};
use xmloxide::validation::xsd::{XsdParseOptions, XsdSchema, parse_xsd_with_options, validate_xsd};
use xmloxide::xinclude::XINCLUDE_NS;

use crate::parse::{parse_xml, RECOVER};
use crate::serialize::{AS_XML, NO_DECLARATION, write_node};
use crate::store::{
    Store, CDATA, COMMENT, DOCUMENT, ELEMENT, HTML_DOCUMENT, PI, TEXT, copy_subtree,
};

const C14N_1_0: i32 = 0;
const C14N_EXCLUSIVE_1_0: i32 = 1;
const C14N_1_1: i32 = 2;

#[derive(TypedData)]
#[magnus(class = "Nokogiri::XML::Schema", free_immediately)]
pub(super) struct SchemaHandle {
    kind: SchemaKind,
}

unsafe impl Send for SchemaHandle {}

impl DataTypeFunctions for SchemaHandle {}

enum SchemaKind {
    Xsd(Box<XsdSchema>),
    Relax(Box<RelaxNgSchema>),
    Broken,
}

pub(super) fn schema_from_document(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    from_document(ruby, class, args, false)
}

pub(super) fn relax_from_document(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    from_document(ruby, class, args, true)
}

pub(super) fn schema_validate_document(ruby: &Ruby, rb_self: Value, document: Value) -> Result<Value, Error> {
    validate_input(ruby, rb_self, document, false)
}

pub(super) fn relax_validate_document(ruby: &Ruby, rb_self: Value, document: Value) -> Result<Value, Error> {
    validate_input(ruby, rb_self, document, false)
}

pub(super) fn schema_validate_file(ruby: &Ruby, rb_self: Value, path: Value) -> Result<Value, Error> {
    let path: String = TryConvert::try_convert(path)?;
    let text = std::fs::read(&path).map(|bytes| String::from_utf8_lossy(&bytes).into_owned()).unwrap_or_default();
    let handle: &SchemaHandle = TryConvert::try_convert(rb_self)?;
    Ok(validate_text(ruby, &handle.kind, &text, true)?.as_value())
}

fn from_document(ruby: &Ruby, class: RClass, args: &[Value], relax: bool) -> Result<Value, Error> {
    let input = *args.first().ok_or_else(|| Error::new(ruby.exception_arg_error(), "wrong number of arguments"))?;
    ensure_node(ruby, input)?;
    let (store, id) = super::handle_from(input)?;
    let kind = store.borrow().nodes[id as usize].kind;
    let (doc_id, ruby_doc) = if kind == DOCUMENT || kind == HTML_DOCUMENT {
        (id, input)
    } else {
        ruby.module_kernel().funcall::<_, _, Value>(
            "warn",
            ("Passing a Node as the first parameter to Schema.from_document is deprecated. Please pass a Document instead. This will become an error in Nokogiri v1.17.0.",),
        )?;
        let ruby_doc: Value = input.funcall("document", ())?;
        (store.borrow().nodes[id as usize].owner, ruby_doc)
    };
    raise_document_errors(ruby, ruby_doc)?;
    let (xml, base) = {
        let store = store.borrow();
        let xml = write_node(&store, doc_id, None, "", AS_XML);
        let base = store.nodes[doc_id as usize].url.clone();
        (xml, base)
    };
    let parse_options = stored_options(ruby, args)?;
    let kind = if relax {
        match relaxng::parse_relaxng(&xml) {
            Ok(schema) => SchemaKind::Relax(Box::new(schema)),
            Err(_) => SchemaKind::Broken,
        }
    } else {
        let resolver = |location: &str, nested: Option<&str>| load_schema(location, nested.or(base.as_deref()));
        match parse_xsd_with_options(
            &xml,
            &XsdParseOptions {
                resolver: Some(&resolver),
                base_uri: base.clone(),
            },
        ) {
            Ok(schema) => SchemaKind::Xsd(Box::new(schema)),
            Err(_) => SchemaKind::Broken,
        }
    };
    let errors = ruby.ary_new();
    if matches!(kind, SchemaKind::Broken) {
        errors.push(syntax_message(ruby, "Could not parse document")?)?;
    }
    let object = ruby.obj_wrap_as(SchemaHandle { kind }, class).as_value();
    super::set_ivar(object, "@errors", errors)?;
    super::set_ivar(object, "@parse_options", parse_options)?;
    Ok(object)
}

fn validate_input(ruby: &Ruby, rb_self: Value, document: Value, file: bool) -> Result<Value, Error> {
    ensure_node(ruby, document)?;
    let (store, id) = super::handle_from(document)?;
    let doc_id = {
        let store = store.borrow();
        let kind = store.nodes[id as usize].kind;
        if kind == DOCUMENT || kind == HTML_DOCUMENT { id } else { store.nodes[id as usize].owner }
    };
    let xml = {
        let store = store.borrow();
        write_node(&store, doc_id, None, "", AS_XML | NO_DECLARATION)
    };
    let handle: &SchemaHandle = TryConvert::try_convert(rb_self)?;
    Ok(validate_text(ruby, &handle.kind, &xml, file)?.as_value())
}

fn validate_text(ruby: &Ruby, kind: &SchemaKind, text: &str, file: bool) -> Result<RArray, Error> {
    let array = ruby.ary_new();
    let fallback = if file { "Could not validate file." } else { "Could not validate document" };
    if matches!(kind, SchemaKind::Broken) {
        array.push(syntax_message(ruby, fallback)?)?;
        return Ok(array);
    }
    let doc = match Document::parse_str(text) {
        Ok(doc) => doc,
        Err(_) => {
            array.push(syntax_message(ruby, fallback)?)?;
            return Ok(array);
        }
    };
    if doc.root_element().is_none() {
        array.push(syntax_message(ruby, fallback)?)?;
        return Ok(array);
    }
    let result = match kind {
        SchemaKind::Xsd(schema) => validate_xsd(&doc, schema),
        SchemaKind::Relax(schema) => relaxng::validate(&doc, schema),
        SchemaKind::Broken => unreachable!(),
    };
    for error in &result.errors {
        array.push(syntax_message(ruby, &error.message)?)?;
    }
    if !result.is_valid && array.len() == 0 {
        array.push(syntax_message(ruby, fallback)?)?;
    }
    Ok(array)
}

fn ensure_node(ruby: &Ruby, value: Value) -> Result<(), Error> {
    let class = node_class(ruby)?;
    if value.is_kind_of(class) {
        return Ok(());
    }
    Err(Error::new(ruby.exception_type_error(), "expected parameter to be a Nokogiri::XML::Document"))
}

fn node_class(ruby: &Ruby) -> Result<RClass, Error> {
    let nokogiri: magnus::RModule = ruby.class_object().const_get("Nokogiri")?;
    let xml: magnus::RModule = nokogiri.const_get("XML")?;
    xml.const_get("Node")
}

fn stored_options(ruby: &Ruby, args: &[Value]) -> Result<Value, Error> {
    if let Some(value) = args.get(1).copied() {
        if !value.is_nil() {
            return Ok(value);
        }
    }
    let nokogiri: magnus::RModule = ruby.class_object().const_get("Nokogiri")?;
    let xml: magnus::RModule = nokogiri.const_get("XML")?;
    let parse_options: Value = xml.const_get("ParseOptions")?;
    parse_options.funcall("const_get", ("DEFAULT_SCHEMA",))
}

fn raise_document_errors(_ruby: &Ruby, document: Value) -> Result<(), Error> {
    let errors = match super::get_ivar(document, "@errors") {
        Ok(value) if !value.is_nil() => value,
        _ => return Ok(()),
    };
    let Ok(array) = <RArray as TryConvert>::try_convert(errors) else {
        return Ok(());
    };
    if array.len() == 0 {
        return Ok(());
    }
    let exception = super::classes().syntax_error.funcall::<_, _, Value>("aggregate", (array,))?;
    if exception.is_nil() {
        return Ok(());
    }
    let exception: Exception = TryConvert::try_convert(exception)?;
    Err(exception.into())
}

fn syntax_message(ruby: &Ruby, message: &str) -> Result<Value, Error> {
    let object = super::classes().syntax_error.new_instance((message,))?;
    super::set_ivar(object, "@path", ruby.qnil())?;
    Ok(object)
}

fn load_schema(location: &str, base: Option<&str>) -> Option<String> {
    let path = local_path(location, base)?;
    std::fs::read_to_string(path).ok()
}

fn local_path(location: &str, base: Option<&str>) -> Option<PathBuf> {
    if is_remote(location) {
        return None;
    }
    if let Some(base) = base {
        if is_remote(base) && !is_file_url(location) && !Path::new(location).is_absolute() {
            return None;
        }
    }
    let location = strip_file_url(location);
    let loc = Path::new(&location);
    if loc.is_absolute() {
        return Some(loc.to_path_buf());
    }
    let dir = match base {
        Some(base) if !is_remote(base) => {
            let base = strip_file_url(base);
            let base = PathBuf::from(base);
            if base.is_dir() { base } else { base.parent().unwrap_or(Path::new(".")).to_path_buf() }
        }
        _ => PathBuf::from("."),
    };
    Some(dir.join(loc))
}

fn is_file_url(value: &str) -> bool {
    value.len() >= 5 && value[..5].eq_ignore_ascii_case("file:")
}

fn is_remote(value: &str) -> bool {
    let Some((scheme, _)) = value.split_once(':') else {
        return false;
    };
    if scheme.eq_ignore_ascii_case("file") {
        return false;
    }
    let scheme = scheme.to_ascii_lowercase();
    matches!(scheme.as_str(), "http" | "https" | "ftp" | "telnet" | "jar") || scheme.starts_with("jar")
}

fn strip_file_url(value: &str) -> String {
    let rest = if value.len() >= 7 && value[..7].eq_ignore_ascii_case("file://") {
        &value[7..]
    } else if value.len() >= 5 && value[..5].eq_ignore_ascii_case("file:") {
        &value[5..]
    } else {
        return value.to_string();
    };
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    if rest.starts_with('/') { rest.to_string() } else { format!("/{rest}") }
}

pub(super) fn canonicalize(ruby: &Ruby, handle: &super::NodeHandle, args: &[Value]) -> Result<String, Error> {
    let mode = match args.first().copied() {
        Some(value) if !value.is_nil() => expect_fixnum(ruby, value)?,
        _ => C14N_1_0,
    };
    let namespaces = match args.get(1).copied() {
        Some(value) if !value.is_nil() => Some(expect_array(ruby, value)?),
        _ => None,
    };
    let with_comments = args.get(2).copied().is_some_and(rtest);
    if namespaces.is_some() && (mode == C14N_1_0 || mode == C14N_1_1) {
        return Err(Error::new(ruby.exception_runtime_error(), "This canonicalizer does not support this operation"));
    }
    let prefixes = namespace_list(namespaces)?;
    let store = handle.store();
    let mut visibility = Visibility::default();
    let children = store.borrow().nodes[handle.id() as usize].children.clone();
    for child in children {
        walk_c14n(ruby, &store, child, mode, &mut visibility)?;
    }
    if ruby.block_given() && visibility.visible_elements == 0 {
        return Ok(String::new());
    }
    let options = C14nOptions {
        with_comments,
        exclusive: mode == C14N_EXCLUSIVE_1_0,
        inclusive_prefixes: prefixes,
    };
    if ruby.block_given() {
        if let Some(root) = subtree_root(&store.borrow(), &visibility.first) {
            let xml = subtree_source(&store.borrow(), root, mode);
            let doc = Document::parse_str(&xml).map_err(|_| Error::new(ruby.exception_runtime_error(), "canonicalization failed"))?;
            return Ok(c14n_document(&doc, &options));
        }
    }
    let xml = c14n_source(&store.borrow());
    let doc = Document::parse_str(&xml).map_err(|_| Error::new(ruby.exception_runtime_error(), "canonicalization failed"))?;
    Ok(c14n_document(&doc, &options))
}

#[derive(Default)]
struct Visibility {
    first: HashMap<u32, bool>,
    elements: usize,
    visible_elements: usize,
}

fn walk_c14n(ruby: &Ruby, store: &Rc<RefCell<Store>>, id: u32, mode: i32, visibility: &mut Visibility) -> Result<(), Error> {
    let (kind, parent) = {
        let store = store.borrow();
        (store.nodes[id as usize].kind, store.nodes[id as usize].parent)
    };
    let seen = call_visible(ruby, store, id, parent)?;
    if kind != ELEMENT {
        return Ok(());
    }
    if let std::collections::hash_map::Entry::Vacant(slot) = visibility.first.entry(id) {
        slot.insert(seen);
        visibility.elements += 1;
        if seen {
            visibility.visible_elements += 1;
        }
    }
    reject_relative_namespace(ruby, store, id)?;
    // C14N 1.0 asks whether the parent was omitted. That callback runs after the
    // element callback and before the element's children. The order test records it.
    if seen && mode == C14N_1_0 {
        if let Some(parent_id) = parent {
            let grand = store.borrow().nodes[parent_id as usize].parent;
            let parent_seen = call_visible(ruby, store, parent_id, grand)?;
            visibility.first.entry(parent_id).or_insert(parent_seen);
        }
    }
    let children = store.borrow().nodes[id as usize].children.clone();
    for child in children {
        walk_c14n(ruby, store, child, mode, visibility)?;
    }
    Ok(())
}

fn call_visible(ruby: &Ruby, store: &Rc<RefCell<Store>>, id: u32, parent: Option<u32>) -> Result<bool, Error> {
    if !ruby.block_given() {
        return Ok(true);
    }
    let node = super::wrap_node(ruby, store, id, None);
    let parent = match parent {
        Some(parent) => super::wrap_node(ruby, store, parent, None),
        None => ruby.qnil().as_value(),
    };
    let result: Value = ruby.yield_values((node, parent))?;
    Ok(rtest(result))
}

fn reject_relative_namespace(ruby: &Ruby, store: &Rc<RefCell<Store>>, id: u32) -> Result<(), Error> {
    let hrefs: Vec<String> = {
        let store = store.borrow();
        store.nodes[id as usize].ns_defs.iter().map(|ns| store.nss[*ns as usize].href.clone()).collect()
    };
    if hrefs.iter().any(|href| href_is_relative(href)) {
        return Err(Error::new(ruby.exception_runtime_error(), "canonicalization failed"));
    }
    Ok(())
}

fn href_is_relative(href: &str) -> bool {
    if href.is_empty() {
        return false;
    }
    match href.split_once(':') {
        Some((scheme, _)) => scheme.is_empty() || !scheme.chars().all(|ch| ch.is_ascii_alphabetic()),
        None => true,
    }
}

fn subtree_root(store: &Store, visible: &HashMap<u32, bool>) -> Option<u32> {
    let mut root = None;
    for (id, seen) in visible {
        if !seen || store.nodes[*id as usize].kind != ELEMENT {
            continue;
        }
        let parent = store.nodes[*id as usize].parent;
        let parent_seen = parent.and_then(|parent| visible.get(&parent).copied()).unwrap_or(false);
        if parent_seen {
            continue;
        }
        if root.is_some() {
            return None;
        }
        root = Some(*id);
    }
    root
}

fn c14n_source(store: &Store) -> String {
    let mut xml = write_node(store, 0, None, "", AS_XML | NO_DECLARATION);
    let keeps_newline = store.nodes[0].children.last().is_some_and(|child| {
        let node = &store.nodes[*child as usize];
        matches!(node.kind, TEXT | CDATA) && node.content.ends_with('\n')
    });
    if !keeps_newline && xml.ends_with('\n') {
        xml.pop();
    }
    xml
}

fn subtree_source(store: &Store, id: u32, mode: i32) -> String {
    let xml = write_node(store, id, None, "", AS_XML | NO_DECLARATION);
    let mut attrs = Vec::new();
    for (prefix, href) in ancestor_namespaces(store, id) {
        attrs.push(xmlns_attr(&prefix, &href));
    }
    if mode != C14N_EXCLUSIVE_1_0 {
        if let Some(value) = inherited_xml(store, id, "lang") {
            attrs.push(format!(" xml:lang=\"{}\"", escape_attr(&value)));
        }
        if let Some(value) = inherited_xml(store, id, "space") {
            attrs.push(format!(" xml:space=\"{}\"", escape_attr(&value)));
        }
    }
    insert_start_attrs(&xml, &attrs)
}

fn ancestor_namespaces(store: &Store, id: u32) -> Vec<(String, String)> {
    let mut seen = HashSet::new();
    for (prefix, _) in namespace_decls(store, id) {
        seen.insert(prefix);
    }
    let mut out = Vec::new();
    let mut current = store.nodes[id as usize].parent;
    while let Some(node) = current {
        if store.nodes[node as usize].kind != ELEMENT {
            break;
        }
        for (prefix, href) in namespace_decls(store, node) {
            if prefix == "xml" || !seen.insert(prefix.clone()) {
                continue;
            }
            out.push((prefix, href));
        }
        current = store.nodes[node as usize].parent;
    }
    out
}

fn namespace_decls(store: &Store, id: u32) -> Vec<(String, String)> {
    store.nodes[id as usize].ns_defs.iter().map(|ns| {
        let data = &store.nss[*ns as usize];
        (data.prefix.clone().unwrap_or_default(), data.href.clone())
    }).collect()
}

fn inherited_xml(store: &Store, id: u32, local: &str) -> Option<String> {
    if xml_special(store, id, local).is_some() {
        return None;
    }
    let mut current = store.nodes[id as usize].parent;
    while let Some(node) = current {
        if store.nodes[node as usize].kind != ELEMENT {
            break;
        }
        if let Some(value) = xml_special(store, node, local) {
            return Some(value);
        }
        current = store.nodes[node as usize].parent;
    }
    None
}

fn xml_special(store: &Store, id: u32, local: &str) -> Option<String> {
    store.nodes[id as usize].attrs.iter().find_map(|attr| {
        let node = &store.nodes[*attr as usize];
        let name = node.name.as_deref().unwrap_or("");
        let attr_local = name.rsplit_once(':').map(|(_, name)| name).unwrap_or(name);
        let xml_ns = name.starts_with("xml:") || node.ns.is_some_and(|ns| store.nss[ns as usize].prefix.as_deref() == Some("xml"));
        (xml_ns && attr_local == local).then(|| node.content.clone())
    })
}

fn xmlns_attr(prefix: &str, href: &str) -> String {
    if prefix.is_empty() {
        format!(" xmlns=\"{}\"", escape_attr(href))
    } else {
        format!(" xmlns:{prefix}=\"{}\"", escape_attr(href))
    }
}

fn escape_attr(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(ch),
        }
    }
    out
}

fn insert_start_attrs(xml: &str, attrs: &[String]) -> String {
    if attrs.is_empty() {
        return xml.to_string();
    }
    let Some(pos) = start_tag_insert(xml) else {
        return xml.to_string();
    };
    let mut out = String::with_capacity(xml.len() + 32);
    out.push_str(&xml[..pos]);
    for attr in attrs {
        out.push_str(attr);
    }
    out.push_str(&xml[pos..]);
    out
}

fn start_tag_insert(xml: &str) -> Option<usize> {
    let bytes = xml.as_bytes();
    if bytes.first() != Some(&b'<') {
        return None;
    }
    let mut quote = None;
    let mut index = 1;
    while index < bytes.len() {
        let byte = bytes[index];
        if let Some(mark) = quote {
            if byte == mark {
                quote = None;
            }
        } else if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
        } else if byte == b'>' {
            if index > 0 && bytes[index - 1] == b'/' {
                return Some(index - 1);
            }
            return Some(index);
        }
        index += 1;
    }
    None
}

fn expect_fixnum(ruby: &Ruby, value: Value) -> Result<i32, Error> {
    i32::try_convert(value).map_err(|_| Error::new(ruby.exception_type_error(), "wrong argument type (expected Integer)"))
}

fn expect_array(ruby: &Ruby, value: Value) -> Result<RArray, Error> {
    TryConvert::try_convert(value).map_err(|_| Error::new(ruby.exception_type_error(), "wrong argument type (expected Array)"))
}

fn namespace_list(namespaces: Option<RArray>) -> Result<Vec<String>, Error> {
    let Some(namespaces) = namespaces else {
        return Ok(Vec::new());
    };
    let mut prefixes = Vec::new();
    for index in 0..namespaces.len() {
        let entry: Value = namespaces.entry(index as isize)?;
        prefixes.push(TryConvert::try_convert(entry)?);
    }
    Ok(prefixes)
}

fn rtest(value: Value) -> bool {
    match bool::try_convert(value) {
        Ok(flag) => flag,
        Err(_) => !value.is_nil(),
    }
}

pub(super) fn process_xincludes(ruby: &Ruby, rb_self: Value, _options: i32) -> Result<Value, Error> {
    let _ = ruby;
    let handle: &super::NodeHandle = TryConvert::try_convert(rb_self)?;
    let store = handle.store();
    let id = handle.id();
    if is_xinclude(&store.borrow(), id, "include") {
        let inserted = expand_include(&store, id, 0);
        for child in inserted {
            walk_xinclude(&store, child, 1);
        }
    } else {
        walk_xinclude(&store, id, 0);
    }
    Ok(rb_self)
}

fn walk_xinclude(store: &Rc<RefCell<Store>>, id: u32, depth: usize) {
    if depth > 50 {
        return;
    }
    let children = store.borrow().nodes[id as usize].children.clone();
    for child in children {
        if is_xinclude(&store.borrow(), child, "include") {
            let inserted = expand_include(store, child, depth);
            for node in inserted {
                walk_xinclude(store, node, depth + 1);
            }
        } else {
            walk_xinclude(store, child, depth);
        }
    }
}

fn expand_include(store: &Rc<RefCell<Store>>, id: u32, _depth: usize) -> Vec<u32> {
    let (href, as_text, base) = {
        let store_ref = store.borrow();
        let href = attribute_value(&store_ref, id, "href");
        let as_text = attribute_value(&store_ref, id, "parse").as_deref() == Some("text");
        let base = store_ref.nodes[0].url.clone();
        (href, as_text, base)
    };
    let loaded = href.as_deref().and_then(|href| {
        let href = href.split('#').next().unwrap_or(href);
        if href.is_empty() { None } else { load_schema(href, base.as_deref()) }
    });
    if let Some(text) = loaded {
        if as_text {
            insert_text_before(store, id, text);
            store.borrow_mut().unlink(id);
            return Vec::new();
        }
        if let Some(ids) = import_included(store, id, &text) {
            return ids;
        }
    }
    fallback_children(store, id).unwrap_or_default()
}

fn import_included(store: &Rc<RefCell<Store>>, include_id: u32, text: &str) -> Option<Vec<u32>> {
    let parsed = parse_xml(text, None, None, RECOVER, super::next_key());
    if parsed.store.borrow().root_element(0).is_none() {
        return None;
    }
    let src_store = parsed.store;
    let mut new_ids = Vec::new();
    {
        let src = src_store.borrow();
        let children = src.nodes[0].children.clone();
        let mut dest = store.borrow_mut();
        for child in children {
            let kind = src.nodes[child as usize].kind;
            if !matches!(kind, ELEMENT | TEXT | CDATA | COMMENT | PI) {
                continue;
            }
            let new_id = copy_subtree(&src, &mut dest, child, 0, true);
            dest.insert_before(include_id, new_id);
            new_ids.push(new_id);
        }
        if new_ids.is_empty() {
            return None;
        }
        dest.unlink(include_id);
    }
    Some(new_ids)
}

fn fallback_children(store: &Rc<RefCell<Store>>, include_id: u32) -> Option<Vec<u32>> {
    let fallback = {
        let store_ref = store.borrow();
        store_ref.nodes[include_id as usize].children.iter().copied().find(|child| is_xinclude(&store_ref, *child, "fallback"))
    }?;
    let kids = store.borrow().nodes[fallback as usize].children.clone();
    {
        let mut store_ref = store.borrow_mut();
        for kid in &kids {
            store_ref.insert_before(include_id, *kid);
        }
        store_ref.unlink(include_id);
    }
    Some(kids)
}

fn insert_text_before(store: &Rc<RefCell<Store>>, include_id: u32, content: String) {
    let mut store = store.borrow_mut();
    let id = store.alloc(TEXT, 0);
    store.nodes[id as usize].name = Some("text".to_string());
    store.nodes[id as usize].content = content;
    store.insert_before(include_id, id);
}

fn is_xinclude(store: &Store, id: u32, local: &str) -> bool {
    let node = &store.nodes[id as usize];
    if node.kind != ELEMENT {
        return false;
    }
    let name = node.name.as_deref().unwrap_or("");
    let local_name = name.rsplit_once(':').map(|(_, local)| local).unwrap_or(name);
    if local_name != local {
        return false;
    }
    node.ns.map(|ns| store.nss[ns as usize].href.as_str()) == Some(XINCLUDE_NS)
}

fn attribute_value(store: &Store, id: u32, name: &str) -> Option<String> {
    store.nodes[id as usize].attrs.iter().find_map(|attr| {
        let node = &store.nodes[*attr as usize];
        (node.name.as_deref() == Some(name)).then(|| node.content.clone())
    })
}
