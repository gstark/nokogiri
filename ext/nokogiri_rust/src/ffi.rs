//! Ruby entry for the flat XML filler.
//!
//! One call copies the source, scans it, and builds the integer columns.
//! The Ruby VM stays locked. The Ruby reader runs when the scan returns nil.

use crate::fill::{self, Bytes, Doc, Prefix};
use std::collections::HashMap;

type Value = usize;

const QNIL: Value = 0x04;
const QTRUE: Value = 0x14;

struct GcGuard {
    was_disabled: bool,
}

impl GcGuard {
    unsafe fn new() -> Self {
        Self { was_disabled: rb_gc_disable() == QTRUE }
    }
}

impl Drop for GcGuard {
    fn drop(&mut self) {
        if !self.was_disabled {
            unsafe { rb_gc_enable() };
        }
    }
}

extern "C" {
    fn rb_define_module(name: *const i8) -> Value;
    fn rb_define_module_under(outer: Value, name: *const i8) -> Value;
    fn rb_define_module_function(module: Value, name: *const i8, func: *const (), argc: i32);
    fn rb_intern(name: *const i8) -> usize;
    fn rb_funcallv(recv: Value, mid: usize, argc: i32, argv: *const Value) -> Value;
    fn rb_ary_new_capa(capa: i64) -> Value;
    fn rb_ary_new_from_values(n: i64, elts: *const Value) -> Value;
    fn rb_ary_push(ary: Value, item: Value) -> Value;
    fn rb_str_subseq(string: Value, beg: i64, len: i64) -> Value;
    fn rb_utf8_str_new(ptr: *const i8, len: i64) -> Value;
    fn rb_string_value_ptr(string: *mut Value) -> *mut i8;
    fn rb_gc_disable() -> Value;
    fn rb_gc_enable() -> Value;
    fn rb_hash_new() -> Value;
    fn rb_hash_aset(hash: Value, key: Value, value: Value) -> Value;
    fn rb_ary_entry(ary: Value, offset: i64) -> Value;
}

#[no_mangle]
pub extern "C" fn Init_nokogiri_rust_flat() {
    unsafe {
        let nokogiri = rb_define_module(c"Nokogiri".as_ptr());
        let pure = rb_define_module_under(nokogiri, c"Pure".as_ptr());
        let flat = rb_define_module_under(pure, c"RustFlat".as_ptr());
        rb_define_module_function(flat, c"columns".as_ptr(), columns as *const (), 2);
        let html5 = rb_define_module_under(pure, c"RustHtml5".as_ptr());
        rb_define_module_function(html5, c"tree".as_ptr(), html_tree as *const (), 2);
    }
}

extern "C" fn columns(_module: Value, string: Value, origin: Value) -> Value {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
        columns_inner(string, origin)
    }));
    match result {
        Ok(value) => value,
        Err(_) => QNIL,
    }
}

unsafe fn columns_inner(string: Value, origin: Value) -> Value {
    let Some(origin) = fix_to_usize(origin) else {
        return QNIL;
    };
    let len_val = rb_funcallv(string, rb_intern(c"bytesize".as_ptr()), 0, std::ptr::null());
    let Some(len) = fix_to_usize(len_val) else {
        return QNIL;
    };
    if origin > len {
        return QNIL;
    }
    let mut slot = string;
    let ptr = rb_string_value_ptr(&mut slot);
    if ptr.is_null() && len > 0 {
        return QNIL;
    }
    let bytes = if len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(ptr as *const u8, len).to_vec()
    };
    let Some(doc) = fill::parse(&bytes, origin) else {
        return QNIL;
    };
    let _gc = GcGuard::new();
    materialize(string, &bytes, &doc)
}

unsafe fn materialize(string: Value, source: &[u8], doc: &Doc) -> Value {
    let mut names: HashMap<Vec<u8>, Value> = HashMap::new();
    let result = rb_ary_new_capa(20);
    rb_ary_push(result, i32_column(&doc.typ));
    rb_ary_push(result, i32_column(&doc.parent));
    rb_ary_push(result, i32_column(&doc.nex));
    rb_ary_push(result, i32_column(&doc.child));
    rb_ary_push(result, i32_column(&doc.off));
    rb_ary_push(result, i32_column(&doc.len));
    rb_ary_push(result, i32_column(&doc.local));
    rb_ary_push(result, i32_column(&doc.ns));
    rb_ary_push(result, i32_column(&doc.line));
    rb_ary_push(result, i32_column(&doc.text_off));
    rb_ary_push(result, i32_column(&doc.text_len));
    rb_ary_push(result, i32_column(&doc.tail));
    rb_ary_push(result, long2fix(doc.top_head as i64));
    rb_ary_push(result, long2fix(doc.top_tail as i64));
    rb_ary_push(result, prefix_column(string, source, doc));
    rb_ary_push(result, href_column(string, source, doc));
    let (attrs, langs) = attr_columns(string, source, doc, &mut names);
    rb_ary_push(result, attrs);
    rb_ary_push(result, def_column(doc));
    rb_ary_push(result, langs);
    let xml_id = match doc.xml_builtin {
        Some(id) => long2fix(id as i64),
        None => QNIL,
    };
    rb_ary_push(result, xml_id);
    result
}

unsafe fn i32_column(col: &[i32]) -> Value {
    if col.is_empty() {
        return rb_ary_new_capa(0);
    }
    let mut buf = Vec::with_capacity(col.len());
    for &number in col {
        buf.push(long2fix(number as i64));
    }
    rb_ary_new_from_values(buf.len() as i64, buf.as_ptr())
}

unsafe fn values_column(values: &[Value]) -> Value {
    if values.is_empty() {
        return rb_ary_new_capa(0);
    }
    rb_ary_new_from_values(values.len() as i64, values.as_ptr())
}

unsafe fn prefix_column(string: Value, source: &[u8], doc: &Doc) -> Value {
    let mut values = Vec::with_capacity(doc.prefixes.len());
    for prefix in &doc.prefixes {
        values.push(match prefix {
            Prefix::None => QNIL,
            Prefix::Slice { off, len } => rb_str_subseq(string, *off as i64, *len as i64),
            Prefix::Xml => utf8(b"xml"),
        });
    }
    let _ = source;
    values_column(&values)
}

unsafe fn href_column(string: Value, source: &[u8], doc: &Doc) -> Value {
    let mut values = Vec::with_capacity(doc.hrefs.len());
    for href in &doc.hrefs {
        values.push(byte_value(string, source, href, false, &mut HashMap::new()));
    }
    values_column(&values)
}

unsafe fn def_column(doc: &Doc) -> Value {
    let mut values = Vec::with_capacity(doc.defs.len());
    for defs in &doc.defs {
        if defs.is_empty() {
            values.push(QNIL);
        } else {
            values.push(i32_column(defs));
        }
    }
    values_column(&values)
}

unsafe fn attr_columns(
    string: Value,
    source: &[u8],
    doc: &Doc,
    names: &mut HashMap<Vec<u8>, Value>,
) -> (Value, Value) {
    let mut attrs = Vec::with_capacity(doc.attrs.len());
    let mut langs = vec![QNIL; doc.langs.len()];
    for (index, list) in doc.attrs.iter().enumerate() {
        if list.is_empty() {
            attrs.push(QNIL);
            continue;
        }
        let ary = rb_ary_new_capa(list.len() as i64);
        for (attr_index, attr) in list.iter().enumerate() {
            let name = intern_slice(names, string, source, attr.name_off, attr.name_len);
            let value = byte_value(string, source, &attr.value, false, names);
            let triple = rb_ary_new_capa(3);
            rb_ary_push(triple, name);
            rb_ary_push(triple, long2fix(attr.ns as i64));
            rb_ary_push(triple, value);
            rb_ary_push(ary, triple);
            if doc.langs[index] == Some(attr_index) {
                langs[index] = value;
            }
        }
        attrs.push(ary);
    }
    (values_column(&attrs), values_column(&langs))
}

unsafe fn byte_value(
    string: Value,
    source: &[u8],
    bytes: &Bytes,
    _intern: bool,
    _names: &mut HashMap<Vec<u8>, Value>,
) -> Value {
    match bytes {
        Bytes::Slice { off, len } => {
            let _ = source;
            rb_str_subseq(string, *off as i64, *len as i64)
        }
        Bytes::Owned(text) => utf8(text),
        Bytes::Xml => utf8(fill::xml_href()),
    }
}

unsafe fn intern_slice(
    names: &mut HashMap<Vec<u8>, Value>,
    string: Value,
    source: &[u8],
    off: usize,
    len: usize,
) -> Value {
    let slice = &source[off..off + len];
    if let Some(&value) = names.get(slice) {
        return value;
    }
    let value = rb_str_subseq(string, off as i64, len as i64);
    names.insert(slice.to_vec(), value);
    value
}

unsafe fn utf8(text: &[u8]) -> Value {
    if text.is_empty() {
        return rb_utf8_str_new(c"".as_ptr(), 0);
    }
    rb_utf8_str_new(text.as_ptr() as *const i8, text.len() as i64)
}

fn long2fix(number: i64) -> Value {
    (((number as u64) << 1) | 1) as Value
}

fn fix_to_usize(value: Value) -> Option<usize> {
    fix_to_i64(value).and_then(|number| if number < 0 { None } else { Some(number as usize) })
}

fn fix_to_i64(value: Value) -> Option<i64> {
    if value & 1 != 1 {
        return None;
    }
    Some((value as i64) >> 1)
}

const QFALSE: Value = 0;

extern "C" fn html_tree(_module: Value, string: Value, options: Value) -> Value {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
        html_tree_inner(string, options)
    }));
    match result {
        Ok(value) => value,
        Err(_) => QNIL,
    }
}

unsafe fn html_tree_inner(string: Value, options: Value) -> Value {
    let Some(packed) = read_html_options(options) else {
        return QNIL;
    };
    let bytes = ruby_bytes(string);
    let text = String::from_utf8_lossy(&bytes);
    let output = crate::html5::parse(text.as_ref(), &packed);
    let _guard = GcGuard::new();
    let keys = HtmlKeys::new();
    let hash = rb_hash_new();
    rb_hash_aset(hash, keys.document, node_hash(&keys, &output.document));
    let root = match &output.root {
        Some(node) => node_hash(&keys, node),
        None => QNIL,
    };
    rb_hash_aset(hash, keys.root, root);
    rb_hash_aset(hash, keys.errors, error_list(&keys, &output.errors));
    rb_hash_aset(hash, keys.quirks_mode, long2fix(output.quirks_mode as i64));
    rb_hash_aset(hash, keys.status, utf8(status_name(output.status)));
    hash
}

struct HtmlKeys {
    document: Value,
    root: Value,
    errors: Value,
    quirks_mode: Value,
    status: Value,
    type_: Value,
    children: Value,
    name: Value,
    namespace: Value,
    attrs: Value,
    content: Value,
    data: Value,
    line: Value,
    has_doctype: Value,
    doctype_name: Value,
    public_id: Value,
    system_id: Value,
    code: Value,
    message: Value,
    column: Value,
    byte_offset: Value,
}

impl HtmlKeys {
    unsafe fn new() -> Self {
        Self {
            document: utf8(b"document"),
            root: utf8(b"root"),
            errors: utf8(b"errors"),
            quirks_mode: utf8(b"quirks_mode"),
            status: utf8(b"status"),
            type_: utf8(b"type"),
            children: utf8(b"children"),
            name: utf8(b"name"),
            namespace: utf8(b"namespace"),
            attrs: utf8(b"attrs"),
            content: utf8(b"content"),
            data: utf8(b"data"),
            line: utf8(b"line"),
            has_doctype: utf8(b"has_doctype"),
            doctype_name: utf8(b"doctype_name"),
            public_id: utf8(b"public_id"),
            system_id: utf8(b"system_id"),
            code: utf8(b"code"),
            message: utf8(b"message"),
            column: utf8(b"column"),
            byte_offset: utf8(b"byte_offset"),
        }
    }
}

fn status_name(status: crate::html5::Status) -> &'static [u8] {
    match status {
        crate::html5::Status::Ok => b"ok",
        crate::html5::Status::TooManyAttributes => b"too_many_attributes",
        crate::html5::Status::TreeTooDeep => b"tree_too_deep",
    }
}

unsafe fn node_hash(keys: &HtmlKeys, node: &crate::html5::model::NodeRef) -> Value {
    let inner = node.0.borrow();
    let hash = rb_hash_new();
    rb_hash_aset(hash, keys.type_, utf8(kind_name(inner.kind)));
    rb_hash_aset(hash, keys.name, utf8(inner.name.as_bytes()));
    rb_hash_aset(hash, keys.namespace, ns_value(inner.namespace));
    rb_hash_aset(hash, keys.content, utf8(inner.content.as_bytes()));
    rb_hash_aset(hash, keys.data, utf8(inner.content.as_bytes()));
    rb_hash_aset(hash, keys.line, long2fix(inner.line as i64));
    rb_hash_aset(hash, keys.has_doctype, if inner.has_doctype { QTRUE } else { QFALSE });
    rb_hash_aset(hash, keys.doctype_name, utf8(inner.doctype_name.as_bytes()));
    rb_hash_aset(hash, keys.public_id, utf8(inner.public_id.as_bytes()));
    rb_hash_aset(hash, keys.system_id, utf8(inner.system_id.as_bytes()));
    rb_hash_aset(hash, keys.quirks_mode, long2fix(inner.quirks_mode as i64));
    let mut attrs = Vec::with_capacity(inner.attrs.len());
    for (name, value, namespace) in &inner.attrs {
        let row = rb_ary_new_capa(3);
        rb_ary_push(row, utf8(name.as_bytes()));
        rb_ary_push(row, utf8(value.as_bytes()));
        rb_ary_push(row, match namespace {
            Some(ns) => ns_value(*ns),
            None => QNIL,
        });
        attrs.push(row);
    }
    rb_hash_aset(hash, keys.attrs, values_column(&attrs));
    let mut children = Vec::with_capacity(inner.children.len());
    for child in &inner.children {
        children.push(node_hash(keys, child));
    }
    drop(inner);
    rb_hash_aset(hash, keys.children, values_column(&children));
    hash
}

fn kind_name(kind: crate::html5::model::NodeKind) -> &'static [u8] {
    use crate::html5::model::NodeKind;
    match kind {
        NodeKind::Document => b"document",
        NodeKind::Element => b"element",
        NodeKind::Text => b"text",
        NodeKind::Cdata => b"cdata",
        NodeKind::Comment => b"comment",
    }
}

fn ns_value(namespace: crate::html5::model::Ns) -> Value {
    use crate::html5::model::Ns;
    let name: &[u8] = match namespace {
        Ns::Html => return QNIL,
        Ns::Svg => b"svg",
        Ns::MathMl => b"mathml",
        Ns::Xlink => b"xlink",
        Ns::Xml => b"xml",
        Ns::Xmlns => b"xmlns",
    };
    unsafe { utf8(name) }
}

unsafe fn error_list(keys: &HtmlKeys, errors: &[crate::html5::model::ParseError]) -> Value {
    let mut values = Vec::with_capacity(errors.len());
    for error in errors {
        let hash = rb_hash_new();
        rb_hash_aset(hash, keys.code, utf8(error.code.as_bytes()));
        rb_hash_aset(hash, keys.message, utf8(error.message.as_bytes()));
        rb_hash_aset(hash, keys.line, long2fix(error.line as i64));
        rb_hash_aset(hash, keys.column, long2fix(error.column as i64));
        rb_hash_aset(hash, keys.byte_offset, long2fix(error.byte_offset as i64));
        values.push(hash);
    }
    values_column(&values)
}

unsafe fn read_html_options(options: Value) -> Option<crate::html5::Options> {
    use crate::html5::model::Ns;
    let max_attributes = fix_to_i64(rb_ary_entry(options, 0))?;
    let max_errors = fix_to_i64(rb_ary_entry(options, 1))?;
    let max_tree_depth = fix_to_i64(rb_ary_entry(options, 2))?;
    let noscript = fix_to_i64(rb_ary_entry(options, 3))?;
    let fragment_context = ruby_text(rb_ary_entry(options, 4));
    let namespace = ruby_text(rb_ary_entry(options, 5));
    let fragment_encoding = ruby_text(rb_ary_entry(options, 6));
    let quirks_mode = fix_to_i64(rb_ary_entry(options, 7))? as i32;
    let form_ancestor = fix_to_i64(rb_ary_entry(options, 8))?;
    Some(crate::html5::Options {
        max_attributes,
        max_errors,
        max_tree_depth,
        noscript_as_text: noscript != 0,
        fragment_context,
        fragment_namespace: Ns::from_name(namespace.as_deref().unwrap_or("html")),
        fragment_encoding,
        quirks_mode,
        form_ancestor: form_ancestor != 0,
    })
}

unsafe fn ruby_text(value: Value) -> Option<String> {
    if value == QNIL {
        return None;
    }
    let bytes = ruby_bytes(value);
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

unsafe fn ruby_bytes(string: Value) -> Vec<u8> {
    let len_val = rb_funcallv(string, rb_intern(c"bytesize".as_ptr()), 0, std::ptr::null());
    let len = fix_to_usize(len_val).unwrap_or(0);
    if len == 0 {
        return Vec::new();
    }
    let mut slot = string;
    let ptr = rb_string_value_ptr(&mut slot);
    std::slice::from_raw_parts(ptr as *const u8, len).to_vec()
}
