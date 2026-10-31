//! Ruby entry for the flat XML filler and the HTML5 tree.
//!
//! One call copies the source and builds the result.
//! The Ruby reader runs when the native call returns nil.
//! A panic also returns nil. Magnus would raise `fatal` for it.

use crate::fill::{self, Bytes, Doc, Prefix};
use crate::html5::model::{NodeKind, NodeRef, Ns, Output, ParseError};
use crate::html5::{Options, Status};
use magnus::prelude::*;
use magnus::rb_sys::{AsRawValue, FromRawValue};
use magnus::value::LazyId;
use magnus::{function, Error, Fixnum, RArray, RClass, RObject, RString, Ruby, Value};
use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Disable GC until the result is built.
///
/// Values in Rust heap buffers are not visible to the GC.
struct GcPause<'a> {
    ruby: &'a Ruby,
    restore: bool,
}

impl<'a> GcPause<'a> {
    fn new(ruby: &'a Ruby) -> Self {
        Self { ruby, restore: !ruby.gc_disable() }
    }
}

impl Drop for GcPause<'_> {
    fn drop(&mut self) {
        if self.restore {
            self.ruby.gc_enable();
        }
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let pure = ruby.define_module("Nokogiri")?.define_module("Pure")?;
    pure.define_module("RustFlat")?.define_module_function("columns", function!(columns, 2))?;
    pure.define_module("RustHtml5")?.define_module_function("tree", function!(html_tree, 3))?;
    Ok(())
}

fn columns(ruby: &Ruby, string: Value, origin: Value) -> Result<Value, Error> {
    match catch_unwind(AssertUnwindSafe(|| columns_inner(ruby, string, origin))) {
        Ok(result) => result,
        Err(_) => Ok(nil(ruby)),
    }
}

fn columns_inner(ruby: &Ruby, string: Value, origin: Value) -> Result<Value, Error> {
    let Some(origin) = fix_to_usize(origin) else {
        return Ok(nil(ruby));
    };
    let string = RString::try_convert(string)?;
    let bytes = unsafe { string.as_slice() }.to_vec();
    if origin > bytes.len() {
        return Ok(nil(ruby));
    }
    let Some(doc) = fill::parse(&bytes, origin) else {
        return Ok(nil(ruby));
    };
    let _gc = GcPause::new(ruby);
    materialize(ruby, string, &bytes, &doc)
}

fn materialize(ruby: &Ruby, string: RString, source: &[u8], doc: &Doc) -> Result<Value, Error> {
    let mut names: HashMap<Vec<u8>, Value> = HashMap::new();
    let (attrs, langs) = attr_columns(ruby, string, source, doc, &mut names);
    let xml_id = match doc.xml_builtin {
        Some(id) => int(ruby, id as i64),
        None => nil(ruby),
    };
    let result = [
        i32_column(ruby, &doc.typ),
        i32_column(ruby, &doc.parent),
        i32_column(ruby, &doc.nex),
        i32_column(ruby, &doc.child),
        i32_column(ruby, &doc.off),
        i32_column(ruby, &doc.len),
        i32_column(ruby, &doc.local),
        i32_column(ruby, &doc.ns),
        i32_column(ruby, &doc.line),
        i32_column(ruby, &doc.text_off),
        i32_column(ruby, &doc.text_len),
        i32_column(ruby, &doc.tail),
        int(ruby, doc.top_head as i64),
        int(ruby, doc.top_tail as i64),
        prefix_column(ruby, string, doc),
        href_column(ruby, string, doc),
        attrs,
        def_column(ruby, doc),
        langs,
        xml_id,
    ];
    Ok(values_column(ruby, &result))
}

fn i32_column(ruby: &Ruby, col: &[i32]) -> Value {
    let values: Vec<Value> = col.iter().map(|&number| int(ruby, number as i64)).collect();
    values_column(ruby, &values)
}

fn values_column(ruby: &Ruby, values: &[Value]) -> Value {
    ruby.ary_new_from_values(values).as_value()
}

fn prefix_column(ruby: &Ruby, string: RString, doc: &Doc) -> Value {
    let values: Vec<Value> = doc
        .prefixes
        .iter()
        .map(|prefix| match prefix {
            Prefix::None => nil(ruby),
            Prefix::Slice { off, len } => subseq(string, *off, *len),
            Prefix::Xml => utf8(ruby, b"xml"),
        })
        .collect();
    values_column(ruby, &values)
}

fn href_column(ruby: &Ruby, string: RString, doc: &Doc) -> Value {
    let values: Vec<Value> = doc.hrefs.iter().map(|href| byte_value(ruby, string, href)).collect();
    values_column(ruby, &values)
}

fn def_column(ruby: &Ruby, doc: &Doc) -> Value {
    let values: Vec<Value> = doc
        .defs
        .iter()
        .map(|defs| if defs.is_empty() { nil(ruby) } else { i32_column(ruby, defs) })
        .collect();
    values_column(ruby, &values)
}

fn attr_columns(
    ruby: &Ruby,
    string: RString,
    source: &[u8],
    doc: &Doc,
    names: &mut HashMap<Vec<u8>, Value>,
) -> (Value, Value) {
    let mut attrs = Vec::with_capacity(doc.attrs.len());
    let mut langs = vec![nil(ruby); doc.langs.len()];
    for (index, list) in doc.attrs.iter().enumerate() {
        if list.is_empty() {
            attrs.push(nil(ruby));
            continue;
        }
        let mut triples = Vec::with_capacity(list.len());
        for (attr_index, attr) in list.iter().enumerate() {
            let name = intern_slice(names, string, source, attr.name_off, attr.name_len);
            let value = byte_value(ruby, string, &attr.value);
            triples.push(values_column(ruby, &[name, int(ruby, attr.ns as i64), value]));
            if doc.langs[index] == Some(attr_index) {
                langs[index] = value;
            }
        }
        attrs.push(values_column(ruby, &triples));
    }
    (values_column(ruby, &attrs), values_column(ruby, &langs))
}

fn byte_value(ruby: &Ruby, string: RString, bytes: &Bytes) -> Value {
    match bytes {
        Bytes::Slice { off, len } => subseq(string, *off, *len),
        Bytes::Owned(text) => utf8(ruby, text),
        Bytes::Xml => utf8(ruby, fill::xml_href()),
    }
}

fn intern_slice(
    names: &mut HashMap<Vec<u8>, Value>,
    string: RString,
    source: &[u8],
    off: usize,
    len: usize,
) -> Value {
    let slice = &source[off..off + len];
    if let Some(&value) = names.get(slice) {
        return value;
    }
    let value = subseq(string, off, len);
    names.insert(slice.to_vec(), value);
    value
}

/// Magnus has no wrapper for `rb_str_subseq`. The substring shares the source buffer.
fn subseq(string: RString, off: usize, len: usize) -> Value {
    unsafe { Value::from_raw(rb_sys::rb_str_subseq(string.as_raw(), off as _, len as _)) }
}

fn utf8(ruby: &Ruby, text: &[u8]) -> Value {
    ruby.enc_str_new(text, ruby.utf8_encoding()).as_value()
}

fn int(ruby: &Ruby, number: i64) -> Value {
    ruby.integer_from_i64(number).as_value()
}

fn nil(ruby: &Ruby) -> Value {
    ruby.qnil().as_value()
}

fn fix_to_usize(value: Value) -> Option<usize> {
    fix_to_i64(value).and_then(|number| usize::try_from(number).ok())
}

fn fix_to_i64(value: Value) -> Option<i64> {
    Fixnum::from_value(value).map(Fixnum::to_i64)
}

fn html_tree(ruby: &Ruby, string: Value, options: Value, parent: Value) -> Result<Value, Error> {
    match catch_unwind(AssertUnwindSafe(|| html_tree_inner(ruby, string, options, parent))) {
        Ok(result) => result,
        Err(_) => {
            clear_children(ruby, parent);
            Ok(nil(ruby))
        }
    }
}

fn html_tree_inner(ruby: &Ruby, string: Value, options: Value, parent: Value) -> Result<Value, Error> {
    let Some(packed) = read_html_options(options)? else {
        return Ok(nil(ruby));
    };
    let string = RString::try_convert(string)?;
    let parent = RObject::try_convert(parent)?;
    let bytes = unsafe { string.as_slice() }.to_vec();
    let text = String::from_utf8_lossy(&bytes);
    let output = crate::html5::parse(text.as_ref(), &packed);
    let _gc = GcPause::new(ruby);
    let attached = output.status == Status::Ok;
    if attached {
        attach_output(ruby, parent, &output, packed.fragment_context.is_some())?;
    }
    summary_hash(ruby, &HtmlKeys::new(ruby), &output, attached)
}

const ELEMENT_NODE: i64 = 1;
const ATTRIBUTE_NODE: i64 = 2;
const TEXT_NODE: i64 = 3;
const CDATA_NODE: i64 = 4;
const COMMENT_NODE: i64 = 8;
const DOCUMENT_NODE: i64 = 9;
const HTML_DOCUMENT_NODE: i64 = 13;
const DTD_NODE: i64 = 14;

const SVG_HREF: &[u8] = b"http://www.w3.org/2000/svg";
const MATH_HREF: &[u8] = b"http://www.w3.org/1998/Math/MathML";
const XLINK_HREF: &[u8] = b"http://www.w3.org/1999/xlink";
const XMLNS_HREF: &[u8] = b"http://www.w3.org/2000/xmlns/";

// IDs only. Class objects move when Ruby compacts the heap.
static PURE: LazyId = LazyId::new("@pure");
static CHILDREN: LazyId = LazyId::new("@children");
static ATTRIBUTES: LazyId = LazyId::new("@attributes");
static NAMESPACE_DEFINITIONS: LazyId = LazyId::new("@namespace_definitions");
static TYPE_ID: LazyId = LazyId::new("@type");
static NAME: LazyId = LazyId::new("@name");
static DOCUMENT: LazyId = LazyId::new("@document");
static CONTENT: LazyId = LazyId::new("@content");
static LINE: LazyId = LazyId::new("@line");
static PARENT: LazyId = LazyId::new("@parent");
static NAMESPACE: LazyId = LazyId::new("@namespace");
static EXTERNAL_ID: LazyId = LazyId::new("@external_id");
static SYSTEM_ID: LazyId = LazyId::new("@system_id");

struct RubyTypes {
    element: RClass,
    text: RClass,
    cdata: RClass,
    comment: RClass,
    attr: RClass,
    dtd: RClass,
    namespace: RClass,
    state: RClass,
    empty_list: Value,
}

fn class_at(ruby: &Ruby, path: &str) -> Result<RClass, Error> {
    ruby.class_object().funcall("const_get", (path,))
}

fn ruby_classes(ruby: &Ruby) -> Result<RubyTypes, Error> {
    let state = class_at(ruby, "Nokogiri::Pure::State")?;
    Ok(RubyTypes {
        element: class_at(ruby, "Nokogiri::XML::Element")?,
        text: class_at(ruby, "Nokogiri::XML::Text")?,
        cdata: class_at(ruby, "Nokogiri::XML::CDATA")?,
        comment: class_at(ruby, "Nokogiri::XML::Comment")?,
        attr: class_at(ruby, "Nokogiri::XML::Attr")?,
        dtd: class_at(ruby, "Nokogiri::XML::DTD")?,
        namespace: class_at(ruby, "Nokogiri::XML::Namespace")?,
        empty_list: state.const_get("EMPTY_LIST")?,
        state,
    })
}

fn alloc(class: RClass) -> Result<RObject, Error> {
    RObject::try_convert(class.obj_alloc()?)
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum DeclKind {
    Svg,
    Math,
    Xlink,
    Xmlns,
}

enum AttrNs {
    Xml,
    Declare(DeclKind, &'static [u8], &'static [u8]),
}

#[derive(Clone, Copy)]
struct Tail {
    node: RObject,
    is_text: bool,
}

struct Attacher<'a> {
    ruby: &'a Ruby,
    types: RubyTypes,
    document: RObject,
    output: RObject,
    xml_ns: Option<Value>,
    decls: HashMap<(u64, DeclKind), Value>,
}

fn summary_hash(ruby: &Ruby, keys: &HtmlKeys, output: &Output, attached: bool) -> Result<Value, Error> {
    let hash = ruby.hash_new();
    hash.aset(keys.errors, error_list(ruby, keys, &output.errors)?)?;
    hash.aset(keys.quirks_mode, int(ruby, output.quirks_mode as i64))?;
    hash.aset(keys.status, utf8(ruby, status_name(output.status)))?;
    if attached {
        hash.aset(keys.attached, true)?;
    }
    Ok(hash.as_value())
}

fn clear_children(ruby: &Ruby, parent: Value) {
    let Some(parent) = RObject::from_value(parent) else {
        return;
    };
    let Ok(Some(state)) = parent.ivar_get::<_, Option<RObject>>(*PURE) else {
        return;
    };
    let _ = state.ivar_set(*CHILDREN, ruby.ary_new());
}

fn owner_document(parent: RObject) -> Result<RObject, Error> {
    let state: RObject = parent.ivar_get(*PURE)?;
    match fix_to_i64(state.ivar_get(*TYPE_ID)?) {
        Some(DOCUMENT_NODE) | Some(HTML_DOCUMENT_NODE) => Ok(parent),
        _ => Ok(state.ivar_get::<_, Option<RObject>>(*DOCUMENT)?.unwrap_or(parent)),
    }
}

fn top_children(output: &Output, fragment: bool) -> Vec<NodeRef> {
    if fragment {
        if let Some(root) = &output.root {
            return root.0.borrow().children.clone();
        }
    }
    output.document.0.borrow().children.clone()
}

fn stored_line(line: i32) -> Option<i64> {
    if line <= 0 || line >= 65535 { None } else { Some(line as i64) }
}

fn blank_string(ruby: &Ruby, value: &str) -> Value {
    if value.is_empty() { nil(ruby) } else { utf8(ruby, value.as_bytes()) }
}

fn install_doctype(ruby: &Ruby, types: &RubyTypes, document: RObject, output: &Output) -> Result<(), Error> {
    let (has, name, public_id, system_id) = {
        let inner = output.document.0.borrow();
        (
            inner.has_doctype,
            inner.doctype_name.clone(),
            inner.public_id.clone(),
            inner.system_id.clone(),
        )
    };
    if !has {
        return Ok(());
    }
    let dtd = alloc(types.dtd)?;
    let state = alloc(types.state)?;
    state.ivar_set(*CHILDREN, ruby.ary_new())?;
    state.ivar_set(*ATTRIBUTES, ruby.ary_new())?;
    state.ivar_set(*NAMESPACE_DEFINITIONS, ruby.ary_new())?;
    state.ivar_set(*TYPE_ID, DTD_NODE)?;
    state.ivar_set(*NAME, utf8(ruby, name.as_bytes()))?;
    state.ivar_set(*DOCUMENT, document)?;
    state.ivar_set(*EXTERNAL_ID, blank_string(ruby, &public_id))?;
    state.ivar_set(*SYSTEM_ID, blank_string(ruby, &system_id))?;
    dtd.ivar_set(*PURE, state)?;
    let parent_state: RObject = document.ivar_get(*PURE)?;
    parent_state.ivar_get::<_, RArray>(*CHILDREN)?.push(dtd)?;
    state.ivar_set(*PARENT, document)?;
    Ok(())
}

/// Link the parsed nodes under `parent`. A failure after the first link clears `parent`.
fn attach_output(ruby: &Ruby, parent: RObject, output: &Output, fragment: bool) -> Result<(), Error> {
    let types = ruby_classes(ruby)?;
    let document = owner_document(parent)?;
    if !fragment {
        install_doctype(ruby, &types, document, output)?;
    }
    let children = top_children(output, fragment);
    let mut attacher = Attacher {
        ruby,
        types,
        document,
        output: parent,
        xml_ns: None,
        decls: HashMap::new(),
    };
    let attached = attacher.attach_list(parent, &children, None, None);
    if attached.is_err() {
        clear_children(ruby, parent.as_value());
    }
    attached
}

fn element_decl(namespace: Ns) -> Option<(DeclKind, &'static [u8], &'static [u8])> {
    match namespace {
        Ns::Svg => Some((DeclKind::Svg, b"svg", SVG_HREF)),
        Ns::MathMl => Some((DeclKind::Math, b"math", MATH_HREF)),
        _ => None,
    }
}

fn attr_decl(namespace: Ns) -> Option<AttrNs> {
    match namespace {
        Ns::Xml => Some(AttrNs::Xml),
        Ns::Xlink => Some(AttrNs::Declare(DeclKind::Xlink, b"xlink", XLINK_HREF)),
        Ns::Xmlns => Some(AttrNs::Declare(DeclKind::Xmlns, b"xmlns", XMLNS_HREF)),
        _ => None,
    }
}

impl Attacher<'_> {
    fn attach_list(
        &mut self,
        parent: RObject,
        nodes: &[NodeRef],
        mut anchor: Option<RObject>,
        mut tail: Option<Tail>,
    ) -> Result<(), Error> {
        for node in nodes {
            let (next_anchor, next_tail) = self.attach_node(parent, node, anchor, tail)?;
            anchor = if parent.as_raw() == self.output.as_raw() { None } else { next_anchor };
            tail = next_tail;
        }
        Ok(())
    }

    fn attach_node(
        &mut self,
        parent: RObject,
        node: &NodeRef,
        anchor: Option<RObject>,
        tail: Option<Tail>,
    ) -> Result<(Option<RObject>, Option<Tail>), Error> {
        let kind = node.0.borrow().kind;
        Ok(match kind {
            NodeKind::Element => self.attach_element(parent, node, anchor)?,
            NodeKind::Text => (anchor, self.attach_leaf(parent, node, TEXT_NODE, "text", true, tail)?),
            NodeKind::Cdata => (
                anchor,
                self.attach_leaf(parent, node, CDATA_NODE, "#cdata-section", false, tail)?,
            ),
            NodeKind::Comment => {
                (anchor, self.attach_leaf(parent, node, COMMENT_NODE, "comment", false, tail)?)
            }
            NodeKind::Document => (anchor, tail),
        })
    }

    fn attach_element(
        &mut self,
        parent: RObject,
        node: &NodeRef,
        anchor: Option<RObject>,
    ) -> Result<(Option<RObject>, Option<Tail>), Error> {
        let (name, namespace, attrs, line, children) = {
            let inner = node.0.borrow();
            (
                inner.name.clone(),
                inner.namespace,
                inner.attrs.clone(),
                inner.line,
                inner.children.clone(),
            )
        };
        let element = alloc(self.types.element)?;
        let state = self.element_state(&name, line, children.len(), attrs.len())?;
        element.ivar_set(*PURE, state)?;
        self.link_child(parent, element, state)?;
        let anchor = anchor.unwrap_or(element);
        self.apply_element_ns(state, anchor, namespace)?;
        self.add_attrs(element, state, anchor, &attrs)?;
        self.attach_list(element, &children, Some(anchor), None)?;
        Ok((Some(anchor), Some(Tail { node: element, is_text: false })))
    }

    fn attach_leaf(
        &mut self,
        parent: RObject,
        node: &NodeRef,
        type_id: i64,
        name: &str,
        merge: bool,
        tail: Option<Tail>,
    ) -> Result<Option<Tail>, Error> {
        let (content, line) = {
            let inner = node.0.borrow();
            (inner.content.clone(), inner.line)
        };
        if merge {
            if let Some(tail) = tail {
                if tail.is_text {
                    self.append_text(tail.node, &content)?;
                    return Ok(Some(tail));
                }
            }
        }
        let klass = match type_id {
            TEXT_NODE => self.types.text,
            CDATA_NODE => self.types.cdata,
            _ => self.types.comment,
        };
        let obj = alloc(klass)?;
        let state = self.leaf_state(type_id, name, &content, line)?;
        obj.ivar_set(*PURE, state)?;
        self.link_child(parent, obj, state)?;
        Ok(Some(Tail { node: obj, is_text: merge }))
    }

    fn element_state(&self, name: &str, line: i32, child_capa: usize, attr_capa: usize) -> Result<RObject, Error> {
        let ruby = self.ruby;
        let state = alloc(self.types.state)?;
        state.ivar_set(*TYPE_ID, ELEMENT_NODE)?;
        state.ivar_set(*NAME, utf8(ruby, name.as_bytes()))?;
        state.ivar_set(*DOCUMENT, self.document)?;
        if let Some(line) = stored_line(line) {
            state.ivar_set(*LINE, line)?;
        }
        state.ivar_set(*CHILDREN, ruby.ary_new_capa(child_capa))?;
        state.ivar_set(*ATTRIBUTES, ruby.ary_new_capa(attr_capa))?;
        state.ivar_set(*NAMESPACE_DEFINITIONS, ruby.ary_new())?;
        Ok(state)
    }

    fn leaf_state(&self, type_id: i64, name: &str, content: &str, line: i32) -> Result<RObject, Error> {
        let ruby = self.ruby;
        let state = alloc(self.types.state)?;
        let empty = self.types.empty_list;
        state.ivar_set(*CHILDREN, empty)?;
        state.ivar_set(*ATTRIBUTES, empty)?;
        state.ivar_set(*NAMESPACE_DEFINITIONS, empty)?;
        state.ivar_set(*TYPE_ID, type_id)?;
        state.ivar_set(*NAME, utf8(ruby, name.as_bytes()))?;
        state.ivar_set(*DOCUMENT, self.document)?;
        state.ivar_set(*CONTENT, utf8(ruby, content.as_bytes()))?;
        if let Some(line) = stored_line(line) {
            state.ivar_set(*LINE, line)?;
        }
        Ok(state)
    }

    fn apply_element_ns(&mut self, state: RObject, anchor: RObject, namespace: Ns) -> Result<(), Error> {
        let Some((kind, prefix, href)) = element_decl(namespace) else {
            return Ok(());
        };
        let ns = self.declare(anchor, kind, prefix, href)?;
        state.ivar_set(*NAMESPACE, ns)
    }

    fn add_attrs(
        &mut self,
        element: RObject,
        element_state: RObject,
        anchor: RObject,
        attrs: &[(String, String, Option<Ns>)],
    ) -> Result<(), Error> {
        let list: RArray = element_state.ivar_get(*ATTRIBUTES)?;
        for (name, value, namespace) in attrs {
            let attr = alloc(self.types.attr)?;
            let state = self.attr_state(name, value)?;
            attr.ivar_set(*PURE, state)?;
            state.ivar_set(*PARENT, element)?;
            if let Some(namespace) = namespace {
                let ns = match attr_decl(*namespace) {
                    Some(AttrNs::Xml) => Some(self.xml_namespace()?),
                    Some(AttrNs::Declare(kind, prefix, href)) => Some(self.declare(anchor, kind, prefix, href)?),
                    None => None,
                };
                if let Some(ns) = ns.filter(|ns| !ns.is_nil()) {
                    state.ivar_set(*NAMESPACE, ns)?;
                }
            }
            list.push(attr)?;
        }
        Ok(())
    }

    fn attr_state(&self, name: &str, value: &str) -> Result<RObject, Error> {
        let ruby = self.ruby;
        let state = alloc(self.types.state)?;
        state.ivar_set(*CHILDREN, ruby.ary_new())?;
        state.ivar_set(*ATTRIBUTES, ruby.ary_new())?;
        state.ivar_set(*NAMESPACE_DEFINITIONS, ruby.ary_new())?;
        state.ivar_set(*TYPE_ID, ATTRIBUTE_NODE)?;
        state.ivar_set(*NAME, utf8(ruby, name.as_bytes()))?;
        state.ivar_set(*DOCUMENT, self.document)?;
        state.ivar_set(*CONTENT, utf8(ruby, value.as_bytes()))?;
        Ok(state)
    }

    fn declare(&mut self, anchor: RObject, kind: DeclKind, prefix: &[u8], href: &[u8]) -> Result<Value, Error> {
        if let Some(&found) = self.decls.get(&(anchor.as_raw(), kind)) {
            return Ok(found);
        }
        let ruby = self.ruby;
        let created = self
            .types
            .namespace
            .new_instance((self.document, utf8(ruby, prefix), utf8(ruby, href)))?;
        let anchor_state: RObject = anchor.ivar_get(*PURE)?;
        anchor_state.ivar_get::<_, RArray>(*NAMESPACE_DEFINITIONS)?.push(created)?;
        self.decls.insert((anchor.as_raw(), kind), created);
        Ok(created)
    }

    fn xml_namespace(&mut self) -> Result<Value, Error> {
        if let Some(ns) = self.xml_ns {
            return Ok(ns);
        }
        let ns: Value = self.document.funcall("xml_namespace", ())?;
        self.xml_ns = Some(ns);
        Ok(ns)
    }

    fn append_text(&self, node: RObject, extra: &str) -> Result<(), Error> {
        let state: RObject = node.ivar_get(*PURE)?;
        let current: Value = state.ivar_get(*CONTENT)?;
        let joined: Value = current.funcall("+", (utf8(self.ruby, extra.as_bytes()),))?;
        state.ivar_set(*CONTENT, joined)
    }

    fn link_child(&self, parent: RObject, child: RObject, child_state: RObject) -> Result<(), Error> {
        let parent_state: RObject = parent.ivar_get(*PURE)?;
        parent_state.ivar_get::<_, RArray>(*CHILDREN)?.push(child)?;
        child_state.ivar_set(*PARENT, parent)
    }
}

struct HtmlKeys {
    errors: Value,
    quirks_mode: Value,
    status: Value,
    attached: Value,
    code: Value,
    message: Value,
    line: Value,
    column: Value,
    byte_offset: Value,
}

impl HtmlKeys {
    fn new(ruby: &Ruby) -> Self {
        let key = |name: &[u8]| utf8(ruby, name);
        Self {
            errors: key(b"errors"),
            quirks_mode: key(b"quirks_mode"),
            status: key(b"status"),
            attached: key(b"attached"),
            code: key(b"code"),
            message: key(b"message"),
            line: key(b"line"),
            column: key(b"column"),
            byte_offset: key(b"byte_offset"),
        }
    }
}

fn status_name(status: Status) -> &'static [u8] {
    match status {
        Status::Ok => b"ok",
        Status::TooManyAttributes => b"too_many_attributes",
        Status::TreeTooDeep => b"tree_too_deep",
    }
}

fn error_list(ruby: &Ruby, keys: &HtmlKeys, errors: &[ParseError]) -> Result<Value, Error> {
    let mut values = Vec::with_capacity(errors.len());
    for error in errors {
        let hash = ruby.hash_new();
        hash.aset(keys.code, utf8(ruby, error.code.as_bytes()))?;
        hash.aset(keys.message, utf8(ruby, error.message.as_bytes()))?;
        hash.aset(keys.line, error.line as i64)?;
        hash.aset(keys.column, error.column as i64)?;
        hash.aset(keys.byte_offset, error.byte_offset as i64)?;
        values.push(hash.as_value());
    }
    Ok(values_column(ruby, &values))
}

fn read_html_options(options: Value) -> Result<Option<Options>, Error> {
    let Some(options) = RArray::from_value(options) else {
        return Ok(None);
    };
    let fixnum = |index| options.entry::<Value>(index).map(fix_to_i64);
    let text = |index| options.entry::<Value>(index).and_then(ruby_text);
    let Some(max_attributes) = fixnum(0)? else {
        return Ok(None);
    };
    let Some(max_errors) = fixnum(1)? else {
        return Ok(None);
    };
    let Some(max_tree_depth) = fixnum(2)? else {
        return Ok(None);
    };
    let Some(noscript) = fixnum(3)? else {
        return Ok(None);
    };
    let fragment_context = text(4)?;
    let namespace = text(5)?;
    let fragment_encoding = text(6)?;
    let Some(quirks_mode) = fixnum(7)? else {
        return Ok(None);
    };
    let Some(form_ancestor) = fixnum(8)? else {
        return Ok(None);
    };
    Ok(Some(Options {
        max_attributes,
        max_errors,
        max_tree_depth,
        noscript_as_text: noscript != 0,
        fragment_context,
        fragment_namespace: Ns::from_name(namespace.as_deref().unwrap_or("html")),
        fragment_encoding,
        quirks_mode: quirks_mode as i32,
        form_ancestor: form_ancestor != 0,
    }))
}

fn ruby_text(value: Value) -> Result<Option<String>, Error> {
    if value.is_nil() {
        return Ok(None);
    }
    let string = RString::try_convert(value)?;
    Ok(Some(String::from_utf8_lossy(unsafe { string.as_slice() }).into_owned()))
}
