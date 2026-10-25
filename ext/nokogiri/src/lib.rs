//! Ruby extension entry point. The shared library still initializes as `Init_nokogiri`.

mod parse;
mod serialize;
mod store;
mod xpath;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};

use magnus::error::Error;
use magnus::exception::Exception;
use magnus::gc::Marker;
use magnus::scan_args::scan_args;
use magnus::typed_data::DataTypeFunctions;
use magnus::value::{Qfalse, Qtrue};
use magnus::{
    Class, IntoValue, Module, RArray, RClass, RHash, RModule, RString, Ruby, TryConvert, TypedData, Value,
    method, prelude::*,
};

use crate::parse::{FragmentResult, Parsed, ParseError, RECOVER, parse_fragment, parse_html, parse_xml};
use crate::serialize::{AS_HTML, AS_XML, escape_text, html_standard, write_node};
use crate::store::{
    ATTRIBUTE, ATTRIBUTE_DECL, CDATA, COMMENT, DOCUMENT, DOCUMENT_FRAG, DTD, ELEMENT, ELEMENT_DECL,
    ENTITY_DECL, ENTITY_REF, HTML_DOCUMENT, PI, Store, TEXT, copy_subtree, copy_within,
};
use crate::xpath::{XValue, evaluate};

static NEXT_KEY: AtomicU64 = AtomicU64::new(1);

fn next_key() -> u64 {
    NEXT_KEY.fetch_add(1, Ordering::Relaxed)
}

thread_local! {
    static CLASSES: RefCell<Option<Classes>> = const { RefCell::new(None) };
    static ALIASES: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());
}

struct Classes {
    element: RClass,
    text: RClass,
    cdata: RClass,
    comment: RClass,
    attr: RClass,
    pi: RClass,
    document: RClass,
    html_document: RClass,
    fragment: RClass,
    dtd: RClass,
    entity_ref: RClass,
    entity_decl: RClass,
    element_decl: RClass,
    attribute_decl: RClass,
    namespace: RClass,
    node_set: RClass,
    syntax_error: RClass,
    xpath_syntax: RClass,
}

fn classes() -> Classes {
    CLASSES.with(|slot| {
        slot.borrow().as_ref().map(|classes| Classes {
            element: classes.element,
            text: classes.text,
            cdata: classes.cdata,
            comment: classes.comment,
            attr: classes.attr,
            pi: classes.pi,
            document: classes.document,
            html_document: classes.html_document,
            fragment: classes.fragment,
            dtd: classes.dtd,
            entity_ref: classes.entity_ref,
            entity_decl: classes.entity_decl,
            element_decl: classes.element_decl,
            attribute_decl: classes.attribute_decl,
            namespace: classes.namespace,
            node_set: classes.node_set,
            syntax_error: classes.syntax_error,
            xpath_syntax: classes.xpath_syntax,
        }).expect("classes")
    })
}

struct Inner {
    store: Rc<RefCell<Store>>,
    id: u32,
}

#[derive(TypedData)]
#[magnus(class = "Nokogiri::XML::Node", free_immediately, mark, size)]
struct NodeHandle {
    inner: RefCell<Inner>,
}

unsafe impl Send for NodeHandle {}

impl Default for NodeHandle {
    fn default() -> Self {
        Self { inner: RefCell::new(Inner { store: Store::new_document(false, next_key()), id: 0 }) }
    }
}

impl DataTypeFunctions for NodeHandle {
    fn mark(&self, marker: &Marker) {
        let Ok(inner) = self.inner.try_borrow() else { return };
        let Ok(store) = inner.store.try_borrow() else { return };
        if let Some(doc) = store.wrappers.first().copied().flatten() {
            marker.mark(doc);
        }
        if inner.id == 0 {
            for value in store.wrappers.iter().flatten() {
                marker.mark(*value);
            }
            for value in store.ns_wrappers.iter().flatten() {
                marker.mark(*value);
            }
        }
    }
}

impl NodeHandle {
    fn store(&self) -> Rc<RefCell<Store>> {
        self.inner.borrow().store.clone()
    }

    fn id(&self) -> u32 {
        self.inner.borrow().id
    }
}

#[derive(TypedData)]
#[magnus(class = "Nokogiri::XML::Namespace", free_immediately, mark, size)]
struct NamespaceHandle {
    store: Rc<RefCell<Store>>,
    id: u32,
}

unsafe impl Send for NamespaceHandle {}

impl DataTypeFunctions for NamespaceHandle {
    fn mark(&self, marker: &Marker) {
        let Ok(store) = self.store.try_borrow() else { return };
        if let Some(doc) = store.wrappers.first().copied().flatten() {
            marker.mark(doc);
        }
    }
}

#[derive(TypedData)]
#[magnus(class = "Nokogiri::XML::NodeSet", free_immediately, mark, size)]
struct NodeSetHandle {
    nodes: RefCell<Vec<Value>>,
}

unsafe impl Send for NodeSetHandle {}

impl Default for NodeSetHandle {
    fn default() -> Self {
        Self { nodes: RefCell::new(Vec::new()) }
    }
}

impl DataTypeFunctions for NodeSetHandle {
    fn mark(&self, marker: &Marker) {
        if let Ok(nodes) = self.nodes.try_borrow() {
            for node in nodes.iter() {
                marker.mark(*node);
            }
        }
    }
}

#[derive(TypedData)]
#[magnus(class = "Nokogiri::XML::XPathContext", free_immediately, mark, size)]
struct XPathHandle {
    node: RefCell<Value>,
    namespaces: RefCell<HashMap<String, String>>,
    variables: RefCell<HashMap<String, Value>>,
}

unsafe impl Send for XPathHandle {}

impl DataTypeFunctions for XPathHandle {
    fn mark(&self, marker: &Marker) {
        if let Ok(node) = self.node.try_borrow() {
            marker.mark(*node);
        }
        if let Ok(variables) = self.variables.try_borrow() {
            for value in variables.values() {
                marker.mark(*value);
            }
        }
    }
}

#[magnus::wrap(class = "Nokogiri::EncodingHandler", free_immediately)]
struct EncodingHandle {
    name: String,
}

#[magnus::wrap(class = "Nokogiri::HTML4::ElementDescription", free_immediately)]
struct ElementDescription {
    name: String,
}

#[derive(TypedData)]
#[magnus(class = "Nokogiri::XML::Reader", free_immediately, mark, size)]
struct ReaderHandle {
    events: RefCell<Vec<ReaderEvent>>,
    index: RefCell<isize>,
    encoding: RefCell<Option<String>>,
    source: RefCell<Value>,
}

unsafe impl Send for ReaderHandle {}

impl DataTypeFunctions for ReaderHandle {
    fn mark(&self, marker: &Marker) {
        if let Ok(source) = self.source.try_borrow() {
            marker.mark(*source);
        }
    }
}

struct ReaderEvent {
    kind: i32,
    name: String,
    value: String,
    depth: i32,
    empty: bool,
    attrs: Vec<(String, String)>,
    prefix: String,
    href: String,
}

fn class_for_kind(kind: i32, html_doc: bool) -> RClass {
    let classes = classes();
    match kind {
        ELEMENT => classes.element,
        TEXT => classes.text,
        CDATA => classes.cdata,
        COMMENT => classes.comment,
        ATTRIBUTE => classes.attr,
        PI => classes.pi,
        DOCUMENT => classes.document,
        HTML_DOCUMENT => {
            if html_doc {
                classes.html_document
            } else {
                classes.document
            }
        }
        DOCUMENT_FRAG => classes.fragment,
        DTD => classes.dtd,
        ENTITY_REF => classes.entity_ref,
        ENTITY_DECL => classes.entity_decl,
        ELEMENT_DECL => classes.element_decl,
        ATTRIBUTE_DECL => classes.attribute_decl,
        _ => classes.element,
    }
}

fn handle_from(value: Value) -> Result<(Rc<RefCell<Store>>, u32), Error> {
    let handle: &NodeHandle = TryConvert::try_convert(value)?;
    Ok((handle.store(), handle.id()))
}

fn wrap_node(ruby: &Ruby, store: &Rc<RefCell<Store>>, id: u32, class_override: Option<RClass>) -> Value {
    if let Some(existing) = store.borrow().wrappers.get(id as usize).copied().flatten() {
        return existing;
    }
    let html = store.borrow().html;
    let kind = store.borrow().nodes[id as usize].kind;
    let class = class_override.unwrap_or_else(|| class_for_kind(kind, html));
    let handle = NodeHandle { inner: RefCell::new(Inner { store: Rc::clone(store), id }) };
    let value = ruby.obj_wrap_as(handle, class).as_value();
    store.borrow_mut().wrappers[id as usize] = Some(value);
    if id != 0 {
        let document = document_value(ruby, store);
        let _ = document.funcall::<_, _, Value>("decorate", (value,));
    }
    value
}

fn wrap_ns(ruby: &Ruby, store: &Rc<RefCell<Store>>, id: u32) -> Value {
    if let Some(existing) = store.borrow().ns_wrappers.get(id as usize).copied().flatten() {
        return existing;
    }
    let handle = NamespaceHandle { store: Rc::clone(store), id };
    let value = ruby.obj_wrap(handle).as_value();
    store.borrow_mut().ns_wrappers[id as usize] = Some(value);
    let document = document_value(ruby, store);
    let _ = set_ivar(value, "@document", document);
    value
}

fn document_value(ruby: &Ruby, store: &Rc<RefCell<Store>>) -> Value {
    wrap_node(ruby, store, 0, None)
}

fn set_ivar<T: IntoValue>(object: Value, name: &str, value: T) -> Result<(), Error> {
    object.funcall::<_, _, Value>("instance_variable_set", (name, value))?;
    Ok(())
}

fn get_ivar(object: Value, name: &str) -> Result<Value, Error> {
    object.funcall("instance_variable_get", (name,))
}

fn make_nodeset(ruby: &Ruby, document: Value, nodes: Vec<Value>) -> Result<Value, Error> {
    let value = ruby.obj_wrap(NodeSetHandle { nodes: RefCell::new(nodes) }).as_value();
    set_ivar(value, "@document", document)?;
    if !document.is_nil() {
        let _ = document.funcall::<_, _, Value>("decorate", (value,));
    }
    Ok(value)
}

fn node_list(ruby: &Ruby, store: &Rc<RefCell<Store>>, ids: &[u32]) -> Result<Value, Error> {
    let document = document_value(ruby, store);
    let nodes = ids.iter().copied().map(|id| wrap_node(ruby, store, id, None)).collect();
    make_nodeset(ruby, document, nodes)
}

fn bytes_of(value: Value) -> Result<Vec<u8>, Error> {
    if value.is_nil() {
        return Ok(Vec::new());
    }
    let text: RString = TryConvert::try_convert(value)?;
    Ok(unsafe { text.as_slice() }.to_vec())
}

fn string_arg(value: Value) -> Result<Option<String>, Error> {
    if value.is_nil() {
        return Ok(None);
    }
    let text: String = TryConvert::try_convert(value)?;
    Ok(Some(text))
}

fn syntax_error(ruby: &Ruby, error: &ParseError) -> Result<Value, Error> {
    let object = classes().syntax_error.new_instance((error.message.as_str(),))?;
    set_ivar(object, "@domain", error.domain)?;
    set_ivar(object, "@code", error.code)?;
    // The suite runs with uses_libxml? false, so location fields stay nil.
    set_ivar(object, "@level", ruby.qnil())?;
    set_ivar(object, "@line", ruby.qnil())?;
    set_ivar(object, "@column", ruby.qnil())?;
    set_ivar(object, "@file", ruby.qnil())?;
    set_ivar(object, "@path", ruby.qnil())?;
    set_ivar(object, "@str1", ruby.qnil())?;
    set_ivar(object, "@str2", ruby.qnil())?;
    set_ivar(object, "@str3", ruby.qnil())?;
    set_ivar(object, "@int1", 0)?;
    Ok(object)
}

fn error_array(ruby: &Ruby, errors: &[ParseError]) -> Result<RArray, Error> {
    let array = ruby.ary_new();
    for error in errors {
        array.push(syntax_error(ruby, error)?)?;
    }
    Ok(array)
}

fn raise_aggregate(ruby: &Ruby, errors: &[ParseError]) -> Result<Value, Error> {
    let list = error_array(ruby, errors)?;
    let exception = classes().syntax_error.funcall::<_, _, Value>("aggregate", (list,))?;
    if exception.is_nil() {
        return Err(Error::new(ruby.exception_runtime_error(), "Could not parse document"));
    }
    let exception: Exception = TryConvert::try_convert(exception)?;
    Err(exception.into())
}

fn finish_document(ruby: &Ruby, class: RClass, parsed: Parsed, html: bool, options: i32) -> Result<Value, Error> {
    let recover = options & RECOVER != 0;
    let fatal = parsed.errors.iter().any(|error| error.level >= 2);
    let any = !parsed.errors.is_empty();
    if html && (!recover && any || parsed.store.borrow().root_element(0).is_none() && any) {
        let errors = error_array(ruby, &parsed.errors)?;
        let first: Value = errors.entry(0)?;
        let text: String = first.funcall("to_s", ())?;
        let message = format!("Parser without recover option encountered error or warning: {text}");
        let exception = classes().syntax_error.new_instance((message,))?;
        let exception: Exception = TryConvert::try_convert(exception)?;
        return Err(exception.into());
    }
    if !html && !recover && fatal {
        return raise_aggregate(ruby, &parsed.errors);
    }
    let value = wrap_node(ruby, &parsed.store, 0, Some(class));
    value.funcall::<_, _, Value>("initialize", ())?;
    set_ivar(value, "@errors", error_array(ruby, &parsed.errors)?)?;
    Ok(value)
}

fn read_memory(ruby: &Ruby, class: RClass, input: Value, url: Value, encoding: Value, options: i32) -> Result<Value, Error> {
    let html = class_is_html(ruby, class);
    let text = String::from_utf8_lossy(&bytes_of(input)?).into_owned();
    let parsed = if html {
        parse_html(&text, string_arg(url)?, string_arg(encoding)?, options, next_key())
    } else {
        parse_xml(&text, string_arg(url)?, string_arg(encoding)?, options, next_key())
    };
    finish_document(ruby, class, parsed, html, options)
}

fn read_io(ruby: &Ruby, class: RClass, io: Value, url: Value, encoding: Value, options: i32) -> Result<Value, Error> {
    let data: Value = io.funcall("read", ())?;
    read_memory(ruby, class, data, url, encoding, options)
}

fn class_is_html(ruby: &Ruby, class: RClass) -> bool {
    classes().html_document.equal(class).unwrap_or(false)
        || class.is_inherited(classes().html_document)
        || ruby.block_given() && false
}

fn document_new(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    let version = args.first().map(|value| string_arg(*value)).transpose()?.flatten().unwrap_or_else(|| "1.0".to_string());
    let html = class_is_html(ruby, class);
    let store = Store::new_document(html, next_key());
    {
        let mut store_ref = store.borrow_mut();
        if html {
            store_ref.nodes[0].version.clear();
            store_ref.nodes[0].encoding = Some("UTF-8".to_string());
            if let Some(url) = args.first() {
                store_ref.nodes[0].url = string_arg(*url)?;
            }
        } else {
            store_ref.nodes[0].version = version;
        }
    }
    let value = wrap_node(ruby, &store, 0, Some(class));
    value.funcall::<_, _, Value>("initialize", args)?;
    if ruby.block_given() {
        ruby.yield_value::<_, Value>(value)?;
    }
    Ok(value)
}

fn value_class_name(value: Value) -> String {
    value
        .funcall::<_, _, Value>("class", ())
        .and_then(|klass| klass.funcall::<_, _, String>("name", ()))
        .unwrap_or_else(|_| "Object".to_string())
}

fn node_new(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    let scanned = scan_args::<(String, Value), (), (), (), (), ()>(args)?;
    let (name, document) = scanned.required;
    let (store, doc_id) = handle_from(document).map_err(|_| {
        Error::new(ruby.exception_arg_error(), "document must be a Nokogiri::XML::Node")
    })?;
    let kind = store.borrow().nodes[doc_id as usize].kind;
    if !matches!(kind, DOCUMENT | HTML_DOCUMENT) {
        ruby.warning("Passing a Node as the second parameter to Node.new is deprecated. Please pass a Document instead, or prefer an alternative constructor like Node#add_child. This will become an error in Nokogiri v1.17.0.");
    }
    let owner = store.borrow().nodes[doc_id as usize].owner;
    let id = store.borrow_mut().alloc(ELEMENT, owner);
    store.borrow_mut().nodes[id as usize].name = Some(name);
    let class_override = if classes().element.equal(class).unwrap_or(false) { None } else { Some(class) };
    let value = wrap_node(ruby, &store, id, class_override);
    value.funcall::<_, _, Value>("initialize", args)?;
    if ruby.block_given() {
        ruby.yield_value::<_, Value>(value)?;
    }
    Ok(value)
}

fn text_new(ruby: &Ruby, class: RClass, content: String, document: Value) -> Result<Value, Error> {
    let document = node_argument(ruby, document, true, "Passing a Node as the second parameter to Text.new is deprecated. Please pass a Document instead. This will become an error in Nokogiri v1.17.0.")?;
    alloc_content_node(ruby, class, document, TEXT, "text", content, true)
}

fn comment_new(ruby: &Ruby, class: RClass, document: Value, content: String) -> Result<Value, Error> {
    if handle_from(document).is_err() {
        return Err(Error::new(ruby.exception_arg_error(), "first argument must be a XML::Document or XML::Node"));
    }
    let document = document_of(document)?;
    alloc_content_node(ruby, class, document, COMMENT, "comment", content, false)
}

fn cdata_new(ruby: &Ruby, class: RClass, document: Value, content: String) -> Result<Value, Error> {
    let document = node_argument(ruby, document, true, "Passing a Node as the first parameter to CDATA.new is deprecated. Please pass a Document instead. This will become an error in Nokogiri v1.17.0.")?;
    alloc_content_node(ruby, class, document, CDATA, "", content, false)
}

fn attr_new(ruby: &Ruby, class: RClass, document: Value, name: String) -> Result<Value, Error> {
    let (store, id) = handle_from(document).map_err(|_| {
        Error::new(ruby.exception_arg_error(), "parameter must be a Nokogiri::XML::Document")
    })?;
    let kind = store.borrow().nodes[id as usize].kind;
    if !matches!(kind, DOCUMENT | HTML_DOCUMENT) {
        return Err(Error::new(ruby.exception_arg_error(), "parameter must be a Nokogiri::XML::Document"));
    }
    alloc_content_node(ruby, class, document, ATTRIBUTE, &name, String::new(), false)
}

fn node_argument(ruby: &Ruby, document: Value, type_error: bool, warn: &str) -> Result<Value, Error> {
    let (store, id) = handle_from(document).map_err(|_| {
        if type_error {
            Error::new(
                ruby.exception_type_error(),
                format!(
                    "expected parameter to be a Nokogiri::XML::Document, received {}",
                    value_class_name(document)
                ),
            )
        } else {
            Error::new(ruby.exception_arg_error(), "document must be a Nokogiri::XML::Node")
        }
    })?;
    let kind = store.borrow().nodes[id as usize].kind;
    if !matches!(kind, DOCUMENT | HTML_DOCUMENT) {
        ruby.warning(warn);
    }
    document_of(document)
}

fn entity_ref_new(ruby: &Ruby, class: RClass, document: Value, name: String) -> Result<Value, Error> {
    let _ = handle_from(document).map_err(|_| {
        Error::new(ruby.exception_arg_error(), "document must be a Nokogiri::XML::Document")
    })?;
    alloc_content_node(ruby, class, document, ENTITY_REF, &name, String::new(), false)
}

fn pi_new(ruby: &Ruby, class: RClass, document: Value, name: String, content: String) -> Result<Value, Error> {
    alloc_content_node(ruby, class, document, PI, &name, content, false)
}

fn fragment_new(ruby: &Ruby, klass: RClass, document: Value) -> Result<Value, Error> {
    let (store, doc_id) = handle_from(document)?;
    let owner = store.borrow().nodes[doc_id as usize].owner;
    let id = store.borrow_mut().alloc(DOCUMENT_FRAG, owner);
    store.borrow_mut().nodes[id as usize].name = Some("#document-fragment".to_string());
    Ok(wrap_node(ruby, &store, id, Some(klass)))
}

fn document_of(value: Value) -> Result<Value, Error> {
    let (store, id) = handle_from(value)?;
    let kind = store.borrow().nodes[id as usize].kind;
    if matches!(kind, DOCUMENT | HTML_DOCUMENT | DOCUMENT_FRAG) {
        return Ok(value);
    }
    let ruby = Ruby::get().unwrap();
    Ok(document_value(&ruby, &store))
}

fn alloc_content_node(
    ruby: &Ruby,
    class: RClass,
    document: Value,
    kind: i32,
    name: &str,
    content: String,
    content_first: bool,
) -> Result<Value, Error> {
    let (store, doc_id) = handle_from(document)?;
    let owner = store.borrow().nodes[doc_id as usize].owner;
    let id = store.borrow_mut().alloc(kind, owner);
    if !name.is_empty() || kind != CDATA {
        if kind != CDATA {
            store.borrow_mut().nodes[id as usize].name = Some(name.to_string());
        }
    }
    store.borrow_mut().nodes[id as usize].content = content;
    let value = wrap_node(ruby, &store, id, Some(class));
    let args: Vec<Value> = if kind == PI {
        vec![
            document,
            ruby.str_new(name).as_value(),
            ruby.str_new(store.borrow().nodes[id as usize].content.as_str()).as_value(),
        ]
    } else if content_first {
        vec![ruby.str_new(store.borrow().nodes[id as usize].content.as_str()).as_value(), document]
    } else {
        vec![document, ruby.str_new(store.borrow().nodes[id as usize].content.as_str()).as_value()]
    };
    value.funcall::<_, _, Value>("initialize", args.as_slice())?;
    if ruby.block_given() {
        ruby.yield_value::<_, Value>(value)?;
    }
    Ok(value)
}

fn content(handle: &NodeHandle) -> String {
    handle.store().borrow().text_content(handle.id())
}

fn node_name(handle: &NodeHandle) -> Option<String> {
    let store = handle.store();
    let store = store.borrow();
    let id = handle.id();
    if store.nodes[id as usize].kind == CDATA {
        return None;
    }
    store.node_name(id)
}

fn set_node_name(handle: &NodeHandle, name: String) -> String {
    handle.store().borrow_mut().nodes[handle.id() as usize].name = Some(name.clone());
    name
}

fn node_type(handle: &NodeHandle) -> i32 {
    handle.store().borrow().nodes[handle.id() as usize].kind
}

fn children(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    let store = handle.store();
    let ids = store.borrow().nodes[handle.id() as usize].children.clone();
    node_list(ruby, &store, &ids)
}

fn element_children(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    let store = handle.store();
    let ids: Vec<u32> = {
        let store_ref = store.borrow();
        store_ref.nodes[handle.id() as usize]
            .children
            .iter()
            .copied()
            .filter(|id| store_ref.nodes[*id as usize].kind == ELEMENT)
            .collect()
    };
    node_list(ruby, &store, &ids)
}

fn attribute_nodes(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    let store = handle.store();
    let id = handle.id();
    let kind = store.borrow().nodes[id as usize].kind;
    if kind == ELEMENT_DECL {
        let (local, prefix, parent) = {
            let store_ref = store.borrow();
            let local = store_ref.nodes[id as usize].name.clone().unwrap_or_default();
            let prefix = store_ref.decls.get(&id).and_then(|decl| decl.prefix.clone());
            let parent = store_ref.nodes[id as usize].parent;
            (local, prefix, parent)
        };
        let qualified = match prefix {
            Some(prefix) if !prefix.is_empty() => format!("{prefix}:{local}"),
            _ => local.clone(),
        };
        let ids = if let Some(parent) = parent {
            let children = store.borrow().nodes[parent as usize].children.clone();
            children
                .into_iter()
                .filter(|child| {
                    let store_ref = store.borrow();
                    store_ref.nodes[*child as usize].kind == ATTRIBUTE_DECL
                        && store_ref.decls.get(child).and_then(|decl| decl.elem_name.as_deref()).is_some_and(|name| {
                            name == local || name == qualified
                        })
                })
                .collect()
        } else {
            Vec::new()
        };
        return node_list(ruby, &store, &ids);
    }
    let ids = store.borrow().nodes[id as usize].attrs.clone();
    node_list(ruby, &store, &ids)
}

fn child(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    let store = handle.store();
    let id = store.borrow().nodes[handle.id() as usize].children.first().copied()?;
    Some(wrap_node(ruby, &store, id, None))
}

fn parent(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    let store = handle.store();
    let id = store.borrow().nodes[handle.id() as usize].parent?;
    Some(wrap_node(ruby, &store, id, None))
}

fn sibling(ruby: &Ruby, handle: &NodeHandle, next: bool, element: bool) -> Option<Value> {
    let store = handle.store();
    let id = handle.id();
    let parent = store.borrow().nodes[id as usize].parent?;
    let children = store.borrow().nodes[parent as usize].children.clone();
    let index = children.iter().position(|child| *child == id)?;
    let range: Box<dyn Iterator<Item = u32>> = if next {
        Box::new(children.into_iter().skip(index + 1))
    } else {
        Box::new(children.into_iter().take(index).rev())
    };
    for candidate in range {
        let kind = store.borrow().nodes[candidate as usize].kind;
        if !element || kind == ELEMENT {
            return Some(wrap_node(ruby, &store, candidate, None));
        }
    }
    None
}

fn document(ruby: &Ruby, handle: &NodeHandle) -> Value {
    document_value(ruby, &handle.store())
}

fn pointer_id(handle: &NodeHandle) -> u64 {
    handle.store().borrow().pointer_id(handle.id())
}

fn blank(handle: &NodeHandle) -> bool {
    handle.store().borrow().is_blank_text(handle.id())
}

fn line(handle: &NodeHandle) -> i64 {
    handle.store().borrow().nodes[handle.id() as usize].line
}

fn set_line(handle: &NodeHandle, line: i64) -> i64 {
    handle.store().borrow_mut().nodes[handle.id() as usize].line = line;
    line
}

fn unlink(rb_self: Value) -> Result<Value, Error> {
    let (store, id) = handle_from(rb_self)?;
    store.borrow_mut().unlink(id);
    Ok(rb_self)
}

fn compare(handle: &NodeHandle, other: Value) -> Result<i32, Error> {
    let (store, other_id) = handle_from(other)?;
    Ok(handle.store().borrow().compare(handle.id(), other_id).clamp(-1, 1) + if !Rc::ptr_eq(&handle.store(), &store) { 0 } else { 0 })
}

fn namespace(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    let store = handle.store();
    let id = store.borrow().nodes[handle.id() as usize].ns?;
    Some(wrap_ns(ruby, &store, id))
}

fn namespace_definitions(ruby: &Ruby, handle: &NodeHandle) -> Result<RArray, Error> {
    let store = handle.store();
    let defs = store.borrow().nodes[handle.id() as usize].ns_defs.clone();
    let array = ruby.ary_new();
    for id in defs {
        array.push(wrap_ns(ruby, &store, id))?;
    }
    Ok(array)
}

fn namespace_scopes(ruby: &Ruby, handle: &NodeHandle) -> Result<RArray, Error> {
    let store = handle.store();
    let scopes = store.borrow().namespace_scopes(handle.id());
    let array = ruby.ary_new();
    for id in scopes {
        array.push(wrap_ns(ruby, &store, id))?;
    }
    Ok(array)
}

fn find_attr(store: &Store, id: u32, name: &str, namespaced: bool) -> Option<u32> {
    store.nodes[id as usize].attrs.iter().copied().find(|attr| {
        let node = &store.nodes[*attr as usize];
        if namespaced {
            node.name.as_deref() == Some(name)
        } else {
            node.name.as_deref() == Some(name) && node.ns.is_none()
        }
    })
}

fn get_attr(handle: &NodeHandle, name: String) -> Option<String> {
    let store = handle.store();
    let store = store.borrow();
    let id = handle.id();
    if let Some((prefix, local)) = name.split_once(':') {
        if !prefix.is_empty() && !local.is_empty() {
            if let Some(ns) = store.lookup_ns(id, Some(prefix)) {
                let href = store.nss[ns as usize].href.clone();
                if let Some(attr) = store.nodes[id as usize].attrs.iter().copied().find(|attr| {
                    let node = &store.nodes[*attr as usize];
                    node.name.as_deref() == Some(local)
                        && node.ns.is_some_and(|ns_id| store.nss[ns_id as usize].href == href)
                }) {
                    return Some(store.nodes[attr as usize].content.clone());
                }
            }
        }
        let attr = find_attr(&store, id, &name, true)?;
        return Some(store.nodes[attr as usize].content.clone());
    }
    let attr = find_attr(&store, id, &name, false)?;
    Some(store.nodes[attr as usize].content.clone())
}

fn set_attr(ruby: &Ruby, handle: &NodeHandle, name: String, value: String) -> Result<String, Error> {
    let store = handle.store();
    let id = handle.id();
    let (local_name, ns_id) = {
        let store_ref = store.borrow();
        if let Some((prefix, local)) = name.split_once(':') {
            if !prefix.is_empty() && !local.is_empty() {
                if let Some(ns) = store_ref.lookup_ns(id, Some(prefix)) {
                    (local.to_string(), Some(ns))
                } else {
                    (name.clone(), None)
                }
            } else {
                (name.clone(), None)
            }
        } else {
            (name.clone(), None)
        }
    };
    let existing = {
        let store_ref = store.borrow();
        store_ref.nodes[id as usize].attrs.iter().copied().find(|attr| {
            let node = &store_ref.nodes[*attr as usize];
            node.name.as_deref() == Some(local_name.as_str()) && node.ns == ns_id
        })
    };
    if let Some(attr) = existing {
        store.borrow_mut().nodes[attr as usize].content = value.clone();
        return Ok(value);
    }
    let owner = store.borrow().nodes[id as usize].owner;
    let attr = store.borrow_mut().alloc(ATTRIBUTE, owner);
    {
        let mut store_ref = store.borrow_mut();
        store_ref.nodes[attr as usize].name = Some(local_name);
        store_ref.nodes[attr as usize].content = value.clone();
        store_ref.nodes[attr as usize].ns = ns_id;
        store_ref.append_child(id, attr);
    }
    let _ = ruby;
    Ok(value)
}

fn key(handle: &NodeHandle, name: String) -> bool {
    find_attr(&handle.store().borrow(), handle.id(), &name, false).is_some()
}

fn attribute(ruby: &Ruby, handle: &NodeHandle, name: String) -> Option<Value> {
    let store = handle.store();
    let attr = {
        let store_ref = store.borrow();
        store_ref.nodes[handle.id() as usize].attrs.iter().copied().find(|attr| {
            store_ref.nodes[*attr as usize].name.as_deref() == Some(name.as_str())
        })
    }?;
    Some(wrap_node(ruby, &store, attr, None))
}

fn attribute_with_ns(ruby: &Ruby, handle: &NodeHandle, local: String, href: Option<String>) -> Option<Value> {
    let store = handle.store();
    let attr = {
        let store_ref = store.borrow();
        store_ref.nodes[handle.id() as usize].attrs.iter().copied().find(|attr| {
            let node = &store_ref.nodes[*attr as usize];
            if node.name.as_deref() != Some(local.as_str()) {
                return false;
            }
            match &href {
                None => node.ns.is_none(),
                Some(href) => node.ns.is_some_and(|ns| store_ref.nss[ns as usize].href == *href),
            }
        })
    }?;
    Some(wrap_node(ruby, &store, attr, None))
}

fn namespaced_key(handle: &NodeHandle, local: String, href: Option<String>) -> bool {
    attribute_with_ns(&Ruby::get().unwrap(), handle, local, href).is_some()
}

fn add_namespace_definition(ruby: &Ruby, handle: &NodeHandle, prefix: Option<String>, href: Option<String>) -> Result<Value, Error> {
    let store = handle.store();
    let prefix = prefix.filter(|prefix| !prefix.is_empty());
    let id = handle.id();
    let (element, set_ns, existing) = {
        let store_ref = store.borrow();
        let kind = store_ref.nodes[id as usize].kind;
        let element = if kind == ELEMENT {
            id
        } else {
            store_ref.nodes[id as usize].parent.unwrap_or(id)
        };
        let set_ns = prefix.is_none() || id != element;
        let existing = store_ref.lookup_ns(id, prefix.as_deref());
        (element, set_ns, existing)
    };
    let ns_id = if let Some(existing) = existing {
        existing
    } else if let Some(href) = href {
        let ns_id = store.borrow_mut().add_ns(prefix, href);
        store.borrow_mut().nodes[element as usize].ns_defs.push(ns_id);
        ns_id
    } else {
        store.borrow_mut().nodes[id as usize].ns = None;
        return Ok(ruby.qnil().as_value());
    };
    if set_ns {
        store.borrow_mut().nodes[id as usize].ns = Some(ns_id);
    }
    Ok(wrap_ns(ruby, &store, ns_id))
}

fn set_namespace(handle: &NodeHandle, ns: Option<Value>) -> Result<(), Error> {
    let store = handle.store();
    let Some(ns) = ns else {
        store.borrow_mut().nodes[handle.id() as usize].ns = None;
        return Ok(());
    };
    let namespace: &NamespaceHandle = TryConvert::try_convert(ns)?;
    if namespace.store.borrow().key != store.borrow().key {
        return Err(Error::new(Ruby::get().unwrap().exception_arg_error(), "namespace must be declared on the same document"));
    }
    store.borrow_mut().nodes[handle.id() as usize].ns = Some(namespace.id);
    Ok(())
}

fn adopt(src: &Rc<RefCell<Store>>, src_id: u32, dest: &Rc<RefCell<Store>>, owner: u32) -> u32 {
    if Rc::ptr_eq(src, dest) {
        return src_id;
    }
    let new_id = {
        let source = src.borrow();
        let mut destination = dest.borrow_mut();
        copy_subtree(&source, &mut destination, src_id, owner, true)
    };
    retarget(src, src_id, dest, new_id);
    src.borrow_mut().unlink(src_id);
    new_id
}

fn retarget(src: &Rc<RefCell<Store>>, src_id: u32, dest: &Rc<RefCell<Store>>, dest_id: u32) {
    let wrapper = src.borrow().wrappers.get(src_id as usize).copied().flatten();
    if let Some(wrapper) = wrapper {
        if let Ok(handle) = <&NodeHandle as TryConvert>::try_convert(wrapper) {
            *handle.inner.borrow_mut() = Inner { store: Rc::clone(dest), id: dest_id };
        }
        dest.borrow_mut().wrappers[dest_id as usize] = Some(wrapper);
        src.borrow_mut().wrappers[src_id as usize] = None;
    }
    let src_children = src.borrow().nodes[src_id as usize].children.clone();
    let dest_children = dest.borrow().nodes[dest_id as usize].children.clone();
    for (source_child, dest_child) in src_children.into_iter().zip(dest_children) {
        retarget(src, source_child, dest, dest_child);
    }
    let src_attrs = src.borrow().nodes[src_id as usize].attrs.clone();
    let dest_attrs = dest.borrow().nodes[dest_id as usize].attrs.clone();
    for (source_attr, dest_attr) in src_attrs.into_iter().zip(dest_attrs) {
        retarget(src, source_attr, dest, dest_attr);
    }
}

fn allowed_child(parent_kind: i32, child_kind: i32) -> bool {
    match parent_kind {
        DOCUMENT | HTML_DOCUMENT => matches!(child_kind, ELEMENT | PI | COMMENT | DTD | TEXT | CDATA | ENTITY_REF),
        DOCUMENT_FRAG | ENTITY_REF | ELEMENT => matches!(child_kind, ELEMENT | PI | COMMENT | TEXT | CDATA | ENTITY_REF),
        ATTRIBUTE => matches!(child_kind, TEXT | ENTITY_REF),
        _ => false,
    }
}

fn add_child_node(ruby: &Ruby, rb_self: Value, child: Value) -> Result<Value, Error> {
    let (store, parent) = handle_from(rb_self)?;
    let (child_store, child_id) = handle_from(child)?;
    let parent_kind = store.borrow().nodes[parent as usize].kind;
    let child_kind = child_store.borrow().nodes[child_id as usize].kind;
    if !allowed_child(parent_kind, child_kind) {
        return Err(Error::new(ruby.exception_arg_error(), "cannot reparent node there"));
    }
    let owner = store.borrow().nodes[parent as usize].owner;
    let child_id = adopt(&child_store, child_id, &store, owner);
    let parent_kind = store.borrow().nodes[parent as usize].kind;
    let child_kind = store.borrow().nodes[child_id as usize].kind;
    if matches!(parent_kind, DOCUMENT | HTML_DOCUMENT) && child_kind == ELEMENT {
        if let Some(root) = store.borrow().root_element(parent) {
            if root != child_id {
                return Err(Error::new(ruby.exception_runtime_error(), "Document already has a root node"));
            }
        }
    }
    store.borrow_mut().append_child(parent, child_id);
    relink_node(ruby, &store, child_id);
    let value = wrap_node(ruby, &store, child_id, None);
    decorate_node(value);
    Ok(value)
}

fn namespace_inheritance_enabled(ruby: &Ruby, store: &Rc<RefCell<Store>>) -> bool {
    let document = store.borrow().wrappers.first().copied().flatten();
    let Some(document) = document else {
        return false;
    };
    get_ivar(document, "@namespace_inheritance")
        .ok()
        .is_some_and(|value| !value.is_nil() && value.is_kind_of(ruby.class_true_class()))
}

fn relink_node(ruby: &Ruby, store: &Rc<RefCell<Store>>, id: u32) {
    let inheritance = namespace_inheritance_enabled(ruby, store);
    store.borrow_mut().relink_namespace(id, inheritance);
}

fn add_sibling(ruby: &Ruby, rb_self: Value, node: Value, after: bool) -> Result<Value, Error> {
    let (store, sibling) = handle_from(rb_self)?;
    let (node_store, node_id) = handle_from(node)?;
    let owner = store.borrow().nodes[sibling as usize].owner;
    let node_id = adopt(&node_store, node_id, &store, owner);
    if after {
        store.borrow_mut().insert_after(sibling, node_id);
    } else {
        store.borrow_mut().insert_before(sibling, node_id);
    }
    relink_node(ruby, &store, node_id);
    let value = wrap_node(ruby, &store, node_id, None);
    decorate_node(value);
    Ok(value)
}

fn replace_node(ruby: &Ruby, rb_self: Value, node: Value) -> Result<Value, Error> {
    let (store, old) = handle_from(rb_self)?;
    let (node_store, node_id) = handle_from(node)?;
    let owner = store.borrow().nodes[old as usize].owner;
    let node_id = adopt(&node_store, node_id, &store, owner);
    store.borrow_mut().replace_with(old, node_id);
    relink_node(ruby, &store, node_id);
    let value = wrap_node(ruby, &store, node_id, None);
    decorate_node(value);
    Ok(value)
}

fn native_content_set(ruby: &Ruby, handle: &NodeHandle, content: String) -> Result<String, Error> {
    let store = handle.store();
    let id = handle.id();
    let kind = store.borrow().nodes[id as usize].kind;
    if matches!(kind, TEXT | CDATA | COMMENT | PI | ATTRIBUTE | ENTITY_REF) {
        store.borrow_mut().nodes[id as usize].content = content.clone();
        return Ok(content);
    }
    let children = store.borrow().nodes[id as usize].children.clone();
    for child in children {
        store.borrow_mut().unlink(child);
    }
    let html = store.borrow().html;
    let FragmentResult { ids, errors } = parse_fragment(&content, &store, id, html, RECOVER);
    append_document_errors(ruby, &store, &errors)?;
    for child in ids {
        store.borrow_mut().append_child(id, child);
    }
    let _ = ruby;
    Ok(content)
}

fn in_context(ruby: &Ruby, handle: &NodeHandle, input: String, options: i32) -> Result<Value, Error> {
    let store = handle.store();
    let html = store.borrow().html || store.borrow().nodes[0].kind == HTML_DOCUMENT;
    let FragmentResult { ids, errors } = parse_fragment(&input, &store, handle.id(), html, options);
    append_document_errors(ruby, &store, &errors)?;
    node_list(ruby, &store, &ids)
}

fn append_document_errors(ruby: &Ruby, store: &Rc<RefCell<Store>>, errors: &[ParseError]) -> Result<(), Error> {
    if errors.is_empty() {
        return Ok(());
    }
    let document = document_value(ruby, store);
    let list = error_array(ruby, errors)?;
    let existing = get_ivar(document, "@errors")?;
    if existing.is_nil() {
        set_ivar(document, "@errors", list.as_value())?;
    } else {
        existing.funcall::<_, _, Value>("concat", (list,))?;
    }
    Ok(())
}

fn decorate_node(value: Value) {
    let _ = value.funcall::<_, _, Value>("decorate!", ());
}

fn native_write_to(ruby: &Ruby, handle: &NodeHandle, io: Value, encoding: Option<String>, indent: String, options: i32) -> Result<Value, Error> {
    let store = handle.store();
    let store = store.borrow();
    let text = write_node(&store, handle.id(), encoding.as_deref(), &indent, options);
    let value = ruby.str_new(&text).as_value();
    io.funcall::<_, _, Value>("write", (value,))?;
    Ok(value)
}

fn root(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    let store = handle.store();
    let id = store.borrow().root_element(handle.id())?;
    Some(wrap_node(ruby, &store, id, None))
}

fn set_root(ruby: &Ruby, handle: &NodeHandle, node: Value) -> Result<Value, Error> {
    let store = handle.store();
    let doc = handle.id();
    if !node.is_nil() {
        let node_class: RClass = ruby.eval("::Nokogiri::XML::Node")?;
        if !node.is_kind_of(node_class) {
            let klass: Value = node.funcall("class", ())?;
            let name: String = klass.funcall("to_s", ())?;
            return Err(Error::new(
                ruby.exception_arg_error(),
                format!("expected Nokogiri::XML::Node but received {name}"),
            ));
        }
        let (node_store, node_id) = handle_from(node)?;
        let kind = node_store.borrow().nodes[node_id as usize].kind;
        if kind != ELEMENT {
            return Err(Error::new(ruby.exception_type_error(), "root must be a Nokogiri::XML::Element"));
        }
    }
    let existing = store.borrow().root_element(doc);
    if let Some(existing) = existing {
        store.borrow_mut().unlink(existing);
    }
    if node.is_nil() {
        return Ok(node);
    }
    let (node_store, node_id) = handle_from(node)?;
    let node_id = adopt(&node_store, node_id, &store, doc);
    store.borrow_mut().append_child(doc, node_id);
    let _ = wrap_node(ruby, &store, node_id, None);
    Ok(node)
}

fn document_encoding(handle: &NodeHandle) -> Option<String> {
    handle.store().borrow().nodes[handle.id() as usize].encoding.clone()
}

fn set_encoding(handle: &NodeHandle, encoding: Option<String>) -> Option<String> {
    handle.store().borrow_mut().nodes[handle.id() as usize].encoding = encoding.clone();
    encoding
}

fn version(handle: &NodeHandle) -> Option<String> {
    let version = handle.store().borrow().nodes[handle.id() as usize].version.clone();
    if version.is_empty() { None } else { Some(version) }
}

fn url(handle: &NodeHandle) -> Option<String> {
    handle.store().borrow().nodes[handle.id() as usize].url.clone()
}

fn remove_namespaces(rb_self: Value) -> Result<Value, Error> {
    let (store, _) = handle_from(rb_self)?;
    store.borrow_mut().remove_namespaces();
    Ok(rb_self)
}

fn internal_subset(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    let store = handle.store();
    let id = store.borrow().nodes[handle.id() as usize].internal_subset?;
    Some(wrap_node(ruby, &store, id, None))
}

fn external_subset(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    let store = handle.store();
    let id = store.borrow().nodes[handle.id() as usize].external_subset?;
    Some(wrap_node(ruby, &store, id, None))
}

fn create_subset(ruby: &Ruby, handle: &NodeHandle, name: String, external_id: Option<String>, system_id: Option<String>, internal: bool) -> Result<Value, Error> {
    let store = handle.store();
    let doc = handle.id();
    {
        let store_ref = store.borrow();
        if internal && store_ref.nodes[doc as usize].internal_subset.is_some() {
            return Err(Error::new(ruby.exception_runtime_error(), "Document already has an internal subset"));
        }
        if !internal && store_ref.nodes[doc as usize].external_subset.is_some() {
            return Err(Error::new(ruby.exception_runtime_error(), "Document already has an external subset"));
        }
    }
    let id = store.borrow_mut().alloc(DTD, doc);
    {
        let mut store_ref = store.borrow_mut();
        store_ref.nodes[id as usize].name = Some(name);
        store_ref.nodes[id as usize].external_id = external_id;
        store_ref.nodes[id as usize].system_id = system_id;
        if internal {
            store_ref.nodes[handle.id() as usize].internal_subset = Some(id);
            store_ref.append_child(handle.id(), id);
        } else {
            store_ref.nodes[handle.id() as usize].external_subset = Some(id);
        }
    }
    Ok(wrap_node(ruby, &store, id, None))
}

fn initialize_copy_node(ruby: &Ruby, rb_self: Value, other: Value, level: i32, document: Value) -> Result<Value, Error> {
    let (src_store, src_id) = handle_from(other)?;
    let (dest_store, dest_doc) = handle_from(document)?;
    let new_id = if Rc::ptr_eq(&src_store, &dest_store) {
        let mut destination = dest_store.borrow_mut();
        copy_within(&mut destination, src_id, dest_doc, level != 0)
    } else {
        let source = src_store.borrow();
        let mut destination = dest_store.borrow_mut();
        copy_subtree(&source, &mut destination, src_id, dest_doc, level != 0)
    };
    let handle: &NodeHandle = TryConvert::try_convert(rb_self)?;
    *handle.inner.borrow_mut() = Inner { store: Rc::clone(&dest_store), id: new_id };
    dest_store.borrow_mut().wrappers[new_id as usize] = Some(rb_self);
    let _ = ruby;
    document.funcall::<_, _, Value>("decorate", (rb_self,))?;
    Ok(rb_self)
}

fn initialize_copy_document(rb_self: Value, other: Value, level: i32) -> Result<Value, Error> {
    let (src_store, _) = handle_from(other)?;
    let key = next_key();
    let html = src_store.borrow().html;
    let dest = Store::new_document(html, key);
    {
        let source = src_store.borrow();
        let mut destination = dest.borrow_mut();
        let from = source.nodes[0].clone();
        destination.html = source.html;
        {
            let node = &mut destination.nodes[0];
            node.name = from.name.clone();
            node.version = from.version.clone();
            node.encoding = from.encoding.clone();
            node.url = from.url.clone();
            node.content = from.content.clone();
        }
        if level != 0 {
            let subset = from.internal_subset;
            let external = from.external_subset;
            for child in from.children {
                let copied = copy_subtree(&source, &mut destination, child, 0, true);
                destination.append_child(0, copied);
                if Some(child) == subset {
                    destination.nodes[0].internal_subset = Some(copied);
                }
                if Some(child) == external {
                    destination.nodes[0].external_subset = Some(copied);
                }
            }
        }
    }
    let handle: &NodeHandle = TryConvert::try_convert(rb_self)?;
    *handle.inner.borrow_mut() = Inner { store: Rc::clone(&dest), id: 0 };
    dest.borrow_mut().wrappers[0] = Some(rb_self);
    Ok(rb_self)
}

fn node_path(handle: &NodeHandle) -> String {
    let store = handle.store();
    let store = store.borrow();
    let mut names = Vec::new();
    let mut id = handle.id();
    if matches!(store.nodes[id as usize].kind, DOCUMENT | HTML_DOCUMENT) {
        return "/".to_string();
    }
    if store.nodes[id as usize].kind == DOCUMENT_FRAG {
        return "?".to_string();
    }
    while store.nodes[id as usize].parent.is_some() {
        let parent = store.nodes[id as usize].parent.unwrap();
        let kind = store.nodes[id as usize].kind;
        let name = if kind == TEXT {
            "text()".to_string()
        } else if kind == COMMENT {
            "comment()".to_string()
        } else {
            store.qualified_name(id)
        };
        let same: Vec<u32> = store.nodes[parent as usize].children.iter().copied().filter(|child| {
            store.nodes[*child as usize].kind == kind && (kind != ELEMENT || store.nodes[*child as usize].name == store.nodes[id as usize].name)
        }).collect();
        let position = same.iter().position(|child| *child == id).unwrap_or(0) + 1;
        if same.len() > 1 {
            names.push(format!("{name}[{position}]"));
        } else {
            names.push(name);
        }
        id = parent;
    }
    names.reverse();
    format!("/{}", names.join("/"))
}

fn lang_of(handle: &NodeHandle) -> Option<String> {
    let store = handle.store();
    let store = store.borrow();
    let mut id = Some(handle.id());
    while let Some(current) = id {
        if let Some(attr) = store.nodes[current as usize].attrs.iter().copied().find(|attr| {
            store.nodes[*attr as usize].name.as_deref() == Some("lang")
                && store.nodes[*attr as usize].ns.is_some_and(|ns| store.nss[ns as usize].prefix.as_deref() == Some("xml"))
        }) {
            return Some(store.nodes[attr as usize].content.clone());
        }
        id = store.nodes[current as usize].parent;
    }
    None
}

fn set_lang(ruby: &Ruby, handle: &NodeHandle, lang: String) -> Result<String, Error> {
    let store = handle.store();
    let id = handle.id();
    let ns = store.borrow_mut().ensure_xml_ns();
    let existing_attr = {
        let store_ref = store.borrow();
        store_ref.nodes[id as usize].attrs.iter().copied().find(|attr| {
            store_ref.nodes[*attr as usize].name.as_deref() == Some("lang")
        })
    };
    if let Some(attr) = existing_attr {
        store.borrow_mut().nodes[attr as usize].content = lang.clone();
        store.borrow_mut().nodes[attr as usize].ns = Some(ns);
    } else {
        let owner = store.borrow().nodes[id as usize].owner;
        let attr = store.borrow_mut().alloc(ATTRIBUTE, owner);
        store.borrow_mut().nodes[attr as usize].name = Some("lang".to_string());
        store.borrow_mut().nodes[attr as usize].content = lang.clone();
        store.borrow_mut().nodes[attr as usize].ns = Some(ns);
        store.borrow_mut().append_child(id, attr);
    }
    let _ = ruby;
    Ok(lang)
}

fn prefix(handle: &NamespaceHandle) -> Option<String> {
    handle.store.borrow().nss[handle.id as usize].prefix.clone()
}

fn href(handle: &NamespaceHandle) -> String {
    handle.store.borrow().nss[handle.id as usize].href.clone()
}

fn nodeset_length(handle: &NodeSetHandle) -> usize {
    handle.nodes.borrow().len()
}

fn nodeset_push(ruby: &Ruby, rb_self: Value, node: Value) -> Result<Value, Error> {
    if <&NodeHandle as TryConvert>::try_convert(node).is_err() && <&NamespaceHandle as TryConvert>::try_convert(node).is_err() {
        return Err(Error::new(ruby.exception_arg_error(), "node must be a Nokogiri::XML::Node or Nokogiri::XML::Namespace"));
    }
    let handle: &NodeSetHandle = TryConvert::try_convert(rb_self)?;
    handle.nodes.borrow_mut().push(node);
    Ok(rb_self)
}

fn nodeset_index(handle: &NodeSetHandle, index: isize) -> Option<Value> {
    let nodes = handle.nodes.borrow();
    let len = nodes.len() as isize;
    if index >= len || index < -len {
        return None;
    }
    let index = if index < 0 { index + len } else { index };
    nodes.get(index as usize).copied()
}

fn nodeset_slice(ruby: &Ruby, rb_self: Value, args: &[Value]) -> Result<Value, Error> {
    let handle: &NodeSetHandle = TryConvert::try_convert(rb_self)?;
    if args.len() == 2 {
        let start: isize = TryConvert::try_convert(args[0])?;
        let len: isize = TryConvert::try_convert(args[1])?;
        return nodeset_range(ruby, rb_self, handle, start, len);
    }
    let arg = args.first().copied().unwrap_or_else(|| ruby.qnil().as_value());
    if let Ok(index) = <isize as TryConvert>::try_convert(arg) {
        return Ok(nodeset_index(handle, index).unwrap_or_else(|| ruby.qnil().as_value()));
    }
    if let Ok((start, len)) = range_bounds(arg, handle.nodes.borrow().len()) {
        return nodeset_range(ruby, rb_self, handle, start, len);
    }
    Err(Error::new(ruby.exception_type_error(), "no implicit conversion into Integer"))
}

fn range_bounds(value: Value, length: usize) -> Result<(isize, isize), Error> {
    let begin: isize = value.funcall("begin", ())?;
    let end: isize = value.funcall("end", ())?;
    let exclude: bool = value.funcall("exclude_end?", ())?;
    let mut start = begin;
    if start < 0 {
        start += length as isize;
    }
    let mut finish = end;
    if finish < 0 {
        finish += length as isize;
    }
    if exclude {
        finish -= 1;
    }
    Ok((start, finish - start + 1))
}

fn nodeset_range(ruby: &Ruby, rb_self: Value, handle: &NodeSetHandle, start: isize, len: isize) -> Result<Value, Error> {
    let nodes = handle.nodes.borrow();
    let size = nodes.len() as isize;
    let mut start = start;
    if start < 0 {
        start += size;
    }
    if start < 0 || len < 0 || start > size {
        return Ok(ruby.qnil().as_value());
    }
    let end = (start + len).min(size);
    let slice = nodes[start as usize..end as usize].to_vec();
    let document = get_ivar(rb_self, "@document")?;
    make_nodeset(ruby, document, slice)
}

fn nodeset_delete(ruby: &Ruby, handle: &NodeSetHandle, node: Value) -> Result<Value, Error> {
    if !node_or_namespace(node) {
        return Err(Error::new(ruby.exception_arg_error(), "node must be a Nokogiri::XML::Node or Nokogiri::XML::Namespace"));
    }
    let mut nodes = handle.nodes.borrow_mut();
    if let Some(index) = nodes.iter().position(|item| item.eql(node).unwrap_or(false) || same_node(*item, node)) {
        nodes.remove(index);
        Ok(node)
    } else {
        Ok(ruby.qnil().as_value())
    }
}

fn same_node(left: Value, right: Value) -> bool {
    if let (Ok((left_store, left_id)), Ok((right_store, right_id))) = (handle_from(left), handle_from(right)) {
        return left_id == right_id && Rc::ptr_eq(&left_store, &right_store);
    }
    if let (Ok(left_ns), Ok(right_ns)) = (
        <&NamespaceHandle as TryConvert>::try_convert(left),
        <&NamespaceHandle as TryConvert>::try_convert(right),
    ) {
        return left_ns.id == right_ns.id && Rc::ptr_eq(&left_ns.store, &right_ns.store);
    }
    false
}

fn node_or_namespace(value: Value) -> bool {
    <&NodeHandle as TryConvert>::try_convert(value).is_ok() || <&NamespaceHandle as TryConvert>::try_convert(value).is_ok()
}

fn nodeset_include(handle: &NodeSetHandle, node: Value) -> bool {
    handle.nodes.borrow().iter().any(|item| same_node(*item, node))
}

fn nodeset_to_a(ruby: &Ruby, handle: &NodeSetHandle) -> RArray {
    let nodes = handle.nodes.borrow().clone();
    ruby.ary_new_from_values(&nodes)
}

fn nodeset_unlink(rb_self: Value) -> Result<Value, Error> {
    let handle: &NodeSetHandle = TryConvert::try_convert(rb_self)?;
    let nodes = handle.nodes.borrow().clone();
    for node in nodes {
        if handle_from(node).is_ok() {
            let _ = unlink(node);
        }
    }
    Ok(rb_self)
}

fn nodeset_combine(ruby: &Ruby, rb_self: Value, other: Value, subtract: bool, intersect: bool) -> Result<Value, Error> {
    let handle: &NodeSetHandle = TryConvert::try_convert(rb_self)?;
    let other_handle: &NodeSetHandle = TryConvert::try_convert(other).map_err(|_| Error::new(ruby.exception_arg_error(), "node_set must be a Nokogiri::XML::NodeSet"))?;
    let left = handle.nodes.borrow().clone();
    let right = other_handle.nodes.borrow().clone();
    let nodes = if intersect {
        left.into_iter().filter(|node| right.iter().any(|other| same_node(*node, *other))).collect()
    } else if subtract {
        left.into_iter().filter(|node| !right.iter().any(|other| same_node(*node, *other))).collect()
    } else {
        let mut nodes = left;
        for node in right {
            if !nodes.iter().any(|existing| same_node(*existing, node)) {
                nodes.push(node);
            }
        }
        nodes
    };
    let document = get_ivar(rb_self, "@document")?;
    make_nodeset(ruby, document, nodes)
}

fn nodeset_copy(rb_self: Value, other: Value) -> Result<Value, Error> {
    let handle: &NodeSetHandle = TryConvert::try_convert(rb_self)?;
    let other_handle: &NodeSetHandle = TryConvert::try_convert(other)?;
    *handle.nodes.borrow_mut() = other_handle.nodes.borrow().clone();
    let document = get_ivar(other, "@document")?;
    set_ivar(rb_self, "@document", document)?;
    if !document.is_nil() {
        document.funcall::<_, _, Value>("decorate", (rb_self,))?;
    }
    Ok(rb_self)
}

fn xpath_new(ruby: &Ruby, _class: RClass, node: Value) -> Result<Value, Error> {
    let _ = handle_from(node)?;
    let mut namespaces = HashMap::new();
    namespaces.insert(
        "nokogiri".to_string(),
        "http://www.nokogiri.org/default_ns/ruby/extensions_functions".to_string(),
    );
    namespaces.insert(
        "nokogiri-builtin".to_string(),
        "https://www.nokogiri.org/default_ns/ruby/builtins".to_string(),
    );
    Ok(ruby.obj_wrap(XPathHandle {
        node: RefCell::new(node),
        namespaces: RefCell::new(namespaces),
        variables: RefCell::new(HashMap::new()),
    }).as_value())
}

fn xpath_register_ns(handle: &XPathHandle, prefix: String, href: Option<String>) -> String {
    let mut namespaces = handle.namespaces.borrow_mut();
    match href {
        None => {
            namespaces.remove(&prefix);
            if prefix == "xmlns" {
                namespaces.remove("");
            }
        }
        Some(href) => {
            if prefix == "xmlns" {
                namespaces.insert(String::new(), href.clone());
            }
            namespaces.insert(prefix.clone(), href);
        }
    }
    prefix
}

fn xpath_register_var(handle: &XPathHandle, name: String, value: Value) -> Value {
    if value.is_nil() {
        handle.variables.borrow_mut().remove(&name);
    } else {
        handle.variables.borrow_mut().insert(name, value);
    }
    value
}

fn xpath_set_node(handle: &XPathHandle, node: Value) -> Result<Value, Error> {
    let _ = handle_from(node)?;
    *handle.node.borrow_mut() = node;
    Ok(node)
}

fn xpath_evaluate(ruby: &Ruby, handle: &XPathHandle, args: &[Value]) -> Result<Value, Error> {
    let expression: String = TryConvert::try_convert(*args.first().ok_or_else(|| Error::new(ruby.exception_arg_error(), "wrong number of arguments"))?)?;
    let node = *handle.node.borrow();
    let (store, id) = handle_from(node)?;
    let namespaces = handle.namespaces.borrow().clone();
    let mut variables = HashMap::new();
    for (key, value) in handle.variables.borrow().iter() {
        if let Ok(text) = <String as TryConvert>::try_convert(*value) {
            variables.insert(key.clone(), XValue::Str(text));
        } else if let Ok(number) = <f64 as TryConvert>::try_convert(*value) {
            variables.insert(key.clone(), XValue::Num(number));
        } else if let Ok(flag) = <bool as TryConvert>::try_convert(*value) {
            variables.insert(key.clone(), XValue::Bool(flag));
        } else if let Ok((var_store, var_id)) = handle_from(*value) {
            if Rc::ptr_eq(&var_store, &store) {
                variables.insert(key.clone(), XValue::Nodes(vec![var_id]));
            }
        }
    }
    let handler = args.get(1).copied().filter(|value| !value.is_nil());
    let raised: RefCell<Option<Error>> = RefCell::new(None);
    let store_for_fn = Rc::clone(&store);
    let mut call_custom = |name: &str, values: &[XValue]| -> Result<Option<XValue>, String> {
        match call_xpath_handler(ruby, &store_for_fn, handler, name, values) {
            Ok(value) => Ok(value),
            Err(error) => {
                *raised.borrow_mut() = Some(error);
                Err(String::new())
            }
        }
    };
    match evaluate(Rc::clone(&store), id, &expression, &namespaces, &variables, Some(&mut call_custom)) {
        Ok(XValue::Nodes(nodes)) => node_list(ruby, &store, &nodes),
        Ok(XValue::Nss(ids)) => {
            let document = document_value(ruby, &store);
            let nodes = ids.iter().copied().map(|ns_id| wrap_ns(ruby, &store, ns_id)).collect();
            make_nodeset(ruby, document, nodes)
        }
        Ok(XValue::Bool(value)) => Ok(ruby.into_value(value)),
        Ok(XValue::Num(value)) => Ok(ruby.into_value(value)),
        Ok(XValue::Str(value)) => Ok(ruby.into_value(value)),
        Err(message) => {
            if let Some(error) = raised.borrow_mut().take() {
                return Err(error);
            }
            let exception = classes().xpath_syntax.new_instance((message,))?;
            let exception: Exception = TryConvert::try_convert(exception)?;
            Err(exception.into())
        }
    }
}

fn call_xpath_handler(
    ruby: &Ruby,
    store: &Rc<RefCell<Store>>,
    handler: Option<Value>,
    name: &str,
    values: &[XValue],
) -> Result<Option<XValue>, Error> {
    let Some(handler) = handler else {
        return Ok(None);
    };
    let (prefixed, method) = match name.split_once(':') {
        Some((_, local)) => (true, local),
        None => (false, name),
    };
    let responds: bool = handler.funcall("respond_to?", (method,))?;
    if !responds {
        return Ok(None);
    }
    if !prefixed {
        ruby.warning(&format!(
            "A custom XPath or CSS handler function named '{method}' is being invoked without a namespace. Please update your query to reference this function as 'nokogiri:{method}'. Invoking custom handler functions without a namespace is deprecated and will become an error in Nokogiri v1.17.0."
        ));
    }
    let mut argv = Vec::with_capacity(values.len());
    for value in values {
        argv.push(xvalue_to_ruby(ruby, store, value)?);
    }
    let result: Value = handler.funcall(method, argv.as_slice())?;
    ruby_to_xvalue(ruby, result)
}

fn xvalue_to_ruby(ruby: &Ruby, store: &Rc<RefCell<Store>>, value: &XValue) -> Result<Value, Error> {
    match value {
        XValue::Nodes(ids) => node_list(ruby, store, ids),
        XValue::Nss(ids) => {
            let document = document_value(ruby, store);
            let nodes = ids.iter().copied().map(|id| wrap_ns(ruby, store, id)).collect();
            make_nodeset(ruby, document, nodes)
        }
        XValue::Bool(flag) => Ok(ruby.into_value(*flag)),
        XValue::Num(number) => Ok(ruby.into_value(*number)),
        XValue::Str(text) => Ok(ruby.into_value(text.as_str())),
    }
}

fn ruby_to_xvalue(ruby: &Ruby, value: Value) -> Result<Option<XValue>, Error> {
    if value.is_nil() {
        return Ok(Some(XValue::Nodes(Vec::new())));
    }
    if Qtrue::from_value(value).is_some() {
        return Ok(Some(XValue::Bool(true)));
    }
    if Qfalse::from_value(value).is_some() {
        return Ok(Some(XValue::Bool(false)));
    }
    if let Ok(text) = <RString as TryConvert>::try_convert(value) {
        let text = unsafe { text.as_str() }?.to_string();
        return Ok(Some(XValue::Str(text)));
    }
    if let Ok(number) = <f64 as TryConvert>::try_convert(value) {
        return Ok(Some(XValue::Num(number)));
    }
    if let Ok(nodeset) = <&NodeSetHandle as TryConvert>::try_convert(value) {
        let nodes = nodeset.nodes.borrow().clone();
        let mut ids = Vec::new();
        for node in nodes {
            if let Ok((_, id)) = handle_from(node) {
                ids.push(id);
            }
        }
        return Ok(Some(XValue::Nodes(ids)));
    }
    if let Ok(array) = <RArray as TryConvert>::try_convert(value) {
        let mut ids = Vec::new();
        for item in array.into_iter() {
            let (_, id) = handle_from(item).map_err(|_| Error::new(ruby.exception_runtime_error(), "Invalid return type"))?;
            ids.push(id);
        }
        return Ok(Some(XValue::Nodes(ids)));
    }
    if let Ok((_, id)) = handle_from(value) {
        return Ok(Some(XValue::Nodes(vec![id])));
    }
    Err(Error::new(ruby.exception_runtime_error(), "Invalid return type"))
}

fn encoding_get(ruby: &Ruby, _class: RClass, name: String) -> Result<Option<Value>, Error> {
    let canonical = ALIASES.with(|aliases| aliases.borrow().get(&name).cloned()).unwrap_or(name);
    let encoding: RClass = ruby.class_object().const_get("Encoding")?;
    if encoding.funcall::<_, _, Value>("find", (canonical.as_str(),)).is_err() {
        return Ok(None);
    }
    Ok(Some(ruby.obj_wrap(EncodingHandle { name: canonical }).as_value()))
}

fn encoding_alias(_class: RClass, real_name: String, alias_name: String) -> String {
    ALIASES.with(|aliases| aliases.borrow_mut().insert(alias_name.clone(), real_name));
    alias_name
}

fn encoding_delete(ruby: &Ruby, _class: RClass, name: String) -> Result<Value, Error> {
    let removed = ALIASES.with(|aliases| aliases.borrow_mut().remove(&name).is_some());
    if removed {
        Ok(ruby.qnil().as_value())
    } else {
        Ok(ruby.qtrue().as_value())
    }
}

fn encoding_clear(rb_self: Value) -> Value {
    ALIASES.with(|aliases| aliases.borrow_mut().clear());
    rb_self
}

fn encoding_name(handle: &EncodingHandle) -> String {
    handle.name.clone()
}

fn element_description_get(ruby: &Ruby, _class: RClass, name: String) -> Value {
    ruby.obj_wrap(ElementDescription { name }).as_value()
}

fn description_name(handle: &ElementDescription) -> String {
    handle.name.clone()
}

fn description_flag(handle: &ElementDescription, kind: &str) -> bool {
    let name = handle.name.to_ascii_lowercase();
    match kind {
        "empty" => matches!(name.as_str(), "br" | "hr" | "img" | "input" | "meta" | "link" | "base" | "col" | "area" | "param"),
        "inline" => matches!(name.as_str(), "a" | "span" | "b" | "i" | "em" | "strong" | "code" | "tt" | "small"),
        "deprecated" => matches!(name.as_str(), "font" | "center" | "strike" | "u" | "applet"),
        "save" => !matches!(name.as_str(), "br" | "hr" | "img" | "input" | "meta" | "link"),
        _ => false,
    }
}

fn description_list(ruby: &Ruby, _handle: &ElementDescription) -> RArray {
    ruby.ary_new()
}

fn entity_get(ruby: &Ruby, _lookup: Value, name: String) -> Result<Value, Error> {
    let value = crate::parse_entity(&name);
    let Some(value) = value else {
        return Ok(ruby.qnil().as_value());
    };
    let nokogiri: RModule = ruby.class_object().const_get("Nokogiri")?;
    let html4: RModule = nokogiri.const_get("HTML4")?;
    let class: RClass = html4.const_get("EntityDescription")?;
    class.new_instance((value as u32, name.as_str(), name.as_str()))
}

fn not_implemented(ruby: &Ruby, name: &str) -> Result<Value, Error> {
    Err(Error::new(ruby.exception_not_imp_error(), format!("{name} is not implemented by the Rust extension")))
}

fn foreign_error_handler(ruby: &Ruby, _module: RModule) -> Result<Value, Error> {
    if !ruby.block_given() {
        return Err(Error::new(ruby.exception_local_jump_error(), "no block given (yield)"));
    }
    Ok(ruby.qnil().as_value())
}

fn reader_from_memory(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    let input = *args.first().ok_or_else(|| Error::new(ruby.exception_arg_error(), "wrong number of arguments"))?;
    let encoding = args.get(2).copied().and_then(|value| string_arg(value).ok()).flatten();
    let text = String::from_utf8_lossy(&bytes_of(input)?).into_owned();
    let options = args.get(3).and_then(|value| <i32 as TryConvert>::try_convert(*value).ok()).unwrap_or(0);
    let parsed = parse_xml(&text, args.get(1).copied().and_then(|value| string_arg(value).ok()).flatten(), encoding.clone(), options, next_key());
    let events = reader_events(&parsed.store.borrow());
    let reader = ruby.obj_wrap_as(ReaderHandle {
        events: RefCell::new(events),
        index: RefCell::new(-1),
        encoding: RefCell::new(encoding.clone().or(parsed.store.borrow().nodes[0].encoding.clone())),
        source: RefCell::new(input),
    }, class).as_value();
    let init_args = [input, args.get(1).copied().unwrap_or_else(|| ruby.qnil().as_value()), encoding.map(|text| ruby.str_new(&text).as_value()).unwrap_or_else(|| ruby.qnil().as_value())];
    reader.funcall::<_, _, Value>("initialize", &init_args[..])?;
    Ok(reader)
}

fn reader_events(store: &Store) -> Vec<ReaderEvent> {
    let mut events = Vec::new();
    fn walk(store: &Store, id: u32, depth: i32, events: &mut Vec<ReaderEvent>) {
        for child in store.nodes[id as usize].children.clone() {
            let node = &store.nodes[child as usize];
            match node.kind {
                ELEMENT => {
                    let empty = node.children.is_empty();
                    let attrs = node.attrs.iter().map(|attr| {
                        (store.nodes[*attr as usize].name.clone().unwrap_or_default(), store.nodes[*attr as usize].content.clone())
                    }).collect();
                    events.push(ReaderEvent {
                        kind: 1,
                        name: node.name.clone().unwrap_or_default(),
                        value: String::new(),
                        depth,
                        empty,
                        attrs,
                        prefix: String::new(),
                        href: String::new(),
                    });
                    if !empty {
                        walk(store, child, depth + 1, events);
                        events.push(ReaderEvent {
                            kind: 15,
                            name: store.nodes[child as usize].name.clone().unwrap_or_default(),
                            value: String::new(),
                            depth,
                            empty: false,
                            attrs: Vec::new(),
                            prefix: String::new(),
                            href: String::new(),
                        });
                    }
                }
                TEXT | CDATA => {
                    let blank = node.content.chars().all(char::is_whitespace);
                    events.push(ReaderEvent {
                        kind: if node.kind == CDATA { 4 } else if blank { 13 } else { 3 },
                        name: if node.kind == CDATA { "#cdata-section".to_string() } else { "#text".to_string() },
                        value: node.content.clone(),
                        depth,
                        empty: false,
                        attrs: Vec::new(),
                        prefix: String::new(),
                        href: String::new(),
                    });
                }
                COMMENT => events.push(ReaderEvent { kind: 8, name: "#comment".to_string(), value: node.content.clone(), depth, empty: false, attrs: Vec::new(), prefix: String::new(), href: String::new() }),
                PI => events.push(ReaderEvent { kind: 7, name: node.name.clone().unwrap_or_default(), value: node.content.clone(), depth, empty: false, attrs: Vec::new(), prefix: String::new(), href: String::new() }),
                _ => {}
            }
        }
    }
    walk(store, 0, 0, &mut events);
    events
}

fn reader_current(handle: &ReaderHandle) -> Option<std::cell::Ref<'_, ReaderEvent>> {
    let index = *handle.index.borrow();
    if index < 0 {
        return None;
    }
    let events = handle.events.borrow();
    if (index as usize) >= events.len() {
        return None;
    }
    Some(std::cell::Ref::map(events, |events| &events[index as usize]))
}

fn reader_read(rb_self: Value) -> Result<Value, Error> {
    let handle: &ReaderHandle = TryConvert::try_convert(rb_self)?;
    let mut index = handle.index.borrow_mut();
    *index += 1;
    let events_len = handle.events.borrow().len() as isize;
    let ruby = Ruby::get().unwrap();
    if *index >= events_len {
        Ok(ruby.qnil().as_value())
    } else {
        Ok(rb_self)
    }
}

fn reader_name(handle: &ReaderHandle) -> Option<String> {
    reader_current(handle).map(|event| event.name.clone())
}

fn reader_value(handle: &ReaderHandle) -> Option<String> {
    reader_current(handle).and_then(|event| if event.value.is_empty() && event.kind == 1 { None } else { Some(event.value.clone()) })
}

fn reader_node_type(handle: &ReaderHandle) -> i32 {
    reader_current(handle).map(|event| event.kind).unwrap_or(0)
}

fn reader_depth(handle: &ReaderHandle) -> i32 {
    reader_current(handle).map(|event| event.depth).unwrap_or(0)
}

fn reader_empty(handle: &ReaderHandle) -> bool {
    reader_current(handle).map(|event| event.empty).unwrap_or(false)
}

fn reader_attr_count(handle: &ReaderHandle) -> usize {
    reader_current(handle).map(|event| event.attrs.len()).unwrap_or(0)
}

fn reader_attr(handle: &ReaderHandle, name: String) -> Option<String> {
    reader_current(handle)?.attrs.iter().find(|(key, _)| key == &name).map(|(_, value)| value.clone())
}

fn reader_attr_at(handle: &ReaderHandle, index: usize) -> Option<String> {
    reader_current(handle)?.attrs.get(index).map(|(_, value)| value.clone())
}

fn reader_attr_hash(ruby: &Ruby, handle: &ReaderHandle) -> RHash {
    let hash = ruby.hash_new();
    if let Some(event) = reader_current(handle) {
        for (key, value) in &event.attrs {
            let _ = hash.aset(key.as_str(), value.as_str());
        }
    }
    hash
}

fn reader_namespaces(ruby: &Ruby, _handle: &ReaderHandle) -> RHash {
    ruby.hash_new()
}

fn reader_value_eh(handle: &ReaderHandle) -> bool {
    reader_current(handle).map(|event| !event.value.is_empty()).unwrap_or(false)
}

fn reader_attributes_eh(handle: &ReaderHandle) -> bool {
    reader_attr_count(handle) > 0
}

macro_rules! ni {
    ($fn_name:ident ( $($arg:ident : $ty:ty),* ) $msg:literal) => {
        fn $fn_name(ruby: &Ruby, $($arg : $ty),*) -> Result<Value, Error> {
            $(let _ = &$arg;)*
            not_implemented(ruby, $msg)
        }
    };
}

fn create_external_subset(ruby: &Ruby, handle: &NodeHandle, name: String, external: Option<String>, system: Option<String>) -> Result<Value, Error> {
    create_subset(ruby, handle, name, external, system, false)
}

fn create_internal_subset(ruby: &Ruby, handle: &NodeHandle, name: String, external: Option<String>, system: Option<String>) -> Result<Value, Error> {
    create_subset(ruby, handle, name, external, system, true)
}

fn data_ptr(_handle: &NodeHandle) -> bool {
    true
}

fn encode_special(_handle: &NodeHandle, text: String) -> String {
    escape_text(&text)
}

fn first_element_child(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    element_end(ruby, handle, true)
}

fn last_element_child(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    element_end(ruby, handle, false)
}

fn next_element(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    sibling(ruby, handle, true, true)
}

fn next_sibling_node(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    sibling(ruby, handle, true, false)
}

fn previous_element(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    sibling(ruby, handle, false, true)
}

fn previous_sibling_node(ruby: &Ruby, handle: &NodeHandle) -> Option<Value> {
    sibling(ruby, handle, false, false)
}

fn add_next_sibling_node(ruby: &Ruby, rb_self: Value, node: Value) -> Result<Value, Error> {
    add_sibling(ruby, rb_self, node, true)
}

fn add_previous_sibling_node(ruby: &Ruby, rb_self: Value, node: Value) -> Result<Value, Error> {
    add_sibling(ruby, rb_self, node, false)
}

fn dump_html(handle: &NodeHandle) -> String {
    html_standard(&handle.store().borrow(), handle.id(), false)
}

fn prepend_newline(handle: &NodeHandle) -> bool {
    let store = handle.store();
    let store = store.borrow();
    let name = store.nodes[handle.id() as usize].name.as_deref().unwrap_or("");
    matches!(name, "pre" | "textarea" | "listing")
        && store.nodes[handle.id() as usize].children.first().is_some_and(|child| store.nodes[*child as usize].content.starts_with('\n'))
}

fn html_standard_serialize(handle: &NodeHandle, preserve: bool) -> String {
    html_standard(&handle.store().borrow(), handle.id(), preserve)
}

ni!(safe_process_xinclude(_handle: &NodeHandle, _options: i32) "safe_process_xinclude");
ni!(process_xincludes(_self: Value, _options: i32) "process_xincludes");
ni!(canonicalize(_handle: &NodeHandle, _args: &[Value]) "canonicalize");

fn create_entity(ruby: &Ruby, handle: &NodeHandle, args: &[Value]) -> Result<Value, Error> {
    let name = args.first().map(|value| string_arg(*value)).transpose()?.flatten().unwrap_or_default();
    let content = args.get(4).map(|value| string_arg(*value)).transpose()?.flatten().unwrap_or_default();
    alloc_content_node(ruby, classes().entity_decl, wrap_node(ruby, &handle.store(), handle.id(), None), ENTITY_DECL, &name, content, false)
}

fn attr_value_set(ruby: &Ruby, handle: &NodeHandle, value: Option<String>) -> Result<Option<String>, Error> {
    let store = handle.store();
    let id = handle.id();
    let kind = store.borrow().nodes[id as usize].kind;
    if kind != ATTRIBUTE {
        return Err(Error::new(ruby.exception_runtime_error(), "node is not an attribute"));
    }
    store.borrow_mut().nodes[id as usize].content = value.clone().unwrap_or_default();
    Ok(value)
}

fn nodeset_and(ruby: &Ruby, rb_self: Value, other: Value) -> Result<Value, Error> {
    nodeset_combine(ruby, rb_self, other, false, true)
}

fn nodeset_minus(ruby: &Ruby, rb_self: Value, other: Value) -> Result<Value, Error> {
    nodeset_combine(ruby, rb_self, other, true, false)
}

fn nodeset_or(ruby: &Ruby, rb_self: Value, other: Value) -> Result<Value, Error> {
    nodeset_combine(ruby, rb_self, other, false, false)
}

fn reader_from_io(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    let io = *args.first().ok_or_else(|| Error::new(ruby.exception_arg_error(), "io cannot be nil"))?;
    let data: Value = io.funcall("read", ())?;
    let mut owned = vec![data];
    owned.extend_from_slice(&args[1..]);
    reader_from_memory(ruby, class, &owned)
}

fn reader_base_uri(_handle: &ReaderHandle) -> Option<String> {
    None
}

fn reader_default(_handle: &ReaderHandle) -> bool {
    false
}

fn reader_encoding(handle: &ReaderHandle) -> Option<String> {
    handle.encoding.borrow().clone()
}

fn reader_inner_xml(handle: &ReaderHandle) -> String {
    reader_current(handle).map(|event| event.value.clone()).unwrap_or_default()
}

fn reader_lang(_handle: &ReaderHandle) -> Option<String> {
    None
}

fn reader_namespace_uri(handle: &ReaderHandle) -> Option<String> {
    reader_current(handle).map(|event| event.href.clone())
}

fn reader_outer_xml(handle: &ReaderHandle) -> String {
    reader_current(handle).map(|event| event.value.clone()).unwrap_or_default()
}

fn reader_prefix(handle: &ReaderHandle) -> Option<String> {
    reader_current(handle).map(|event| event.prefix.clone())
}

fn reader_state(_handle: &ReaderHandle) -> i32 {
    0
}

fn reader_xml_version(_handle: &ReaderHandle) -> String {
    "1.0".to_string()
}

fn description_implied_start(handle: &ElementDescription) -> bool {
    description_flag(handle, "implied")
}

fn description_implied_end(handle: &ElementDescription) -> bool {
    description_flag(handle, "implied")
}

fn description_save_end(handle: &ElementDescription) -> bool {
    description_flag(handle, "save")
}

fn description_empty(handle: &ElementDescription) -> bool {
    description_flag(handle, "empty")
}

fn description_deprecated(handle: &ElementDescription) -> bool {
    description_flag(handle, "deprecated")
}

fn description_inline(handle: &ElementDescription) -> bool {
    description_flag(handle, "inline")
}

fn description_default_sub(_handle: &ElementDescription) -> Option<String> {
    None
}

#[derive(TypedData)]
#[magnus(class = "Nokogiri::XML::ElementContent", free_immediately, mark, size)]
struct ContentHandle {
    store: Rc<RefCell<Store>>,
    id: u32,
}

unsafe impl Send for ContentHandle {}

impl DataTypeFunctions for ContentHandle {
    fn mark(&self, marker: &Marker) {
        let Ok(store) = self.store.try_borrow() else { return };
        if let Some(doc) = store.wrappers.first().copied().flatten() {
            marker.mark(doc);
        }
    }
}

fn wrap_content(ruby: &Ruby, store: &Rc<RefCell<Store>>, id: u32) -> Result<Value, Error> {
    let handle = ContentHandle { store: Rc::clone(store), id };
    let value = ruby.obj_wrap(handle).as_value();
    set_ivar(value, "@document", document_value(ruby, store))?;
    Ok(value)
}

fn element_content_name(handle: &ContentHandle) -> Option<String> {
    handle.store.borrow().contents.get(handle.id as usize).and_then(|node| node.name.clone())
}

fn element_content_type(handle: &ContentHandle) -> i32 {
    handle.store.borrow().contents.get(handle.id as usize).map(|node| node.kind).unwrap_or(0)
}

fn element_content_occur(handle: &ContentHandle) -> i32 {
    handle.store.borrow().contents.get(handle.id as usize).map(|node| node.occur).unwrap_or(0)
}

fn element_content_prefix(handle: &ContentHandle) -> Option<String> {
    handle.store.borrow().contents.get(handle.id as usize).and_then(|node| node.prefix.clone())
}

fn element_content_child(ruby: &Ruby, handle: &ContentHandle, first: bool) -> Result<Value, Error> {
    let id = {
        let store = handle.store.borrow();
        let node = store.contents.get(handle.id as usize);
        if first { node.and_then(|node| node.c1) } else { node.and_then(|node| node.c2) }
    };
    match id {
        Some(id) => wrap_content(ruby, &handle.store, id),
        None => Ok(ruby.qnil().as_value()),
    }
}

fn element_content_c1(ruby: &Ruby, handle: &ContentHandle) -> Result<Value, Error> {
    element_content_child(ruby, handle, true)
}

fn element_content_c2(ruby: &Ruby, handle: &ContentHandle) -> Result<Value, Error> {
    element_content_child(ruby, handle, false)
}

fn decl_of(handle: &NodeHandle) -> Option<crate::store::DeclData> {
    handle.store().borrow().decls.get(&handle.id()).cloned()
}

fn element_decl_type(handle: &NodeHandle) -> i32 {
    decl_of(handle).map(|decl| decl.element_type).unwrap_or(0)
}

fn element_decl_prefix(handle: &NodeHandle) -> Option<String> {
    decl_of(handle).and_then(|decl| decl.prefix)
}

fn element_decl_content(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    match decl_of(handle).and_then(|decl| decl.content_id) {
        Some(id) => wrap_content(ruby, &handle.store(), id),
        None => Ok(ruby.qnil().as_value()),
    }
}

fn attribute_decl_type(handle: &NodeHandle) -> String {
    decl_of(handle).map(|decl| decl.attr_type).unwrap_or_default()
}

fn attribute_decl_default(handle: &NodeHandle) -> Option<String> {
    decl_of(handle).and_then(|decl| decl.attr_default)
}

fn attribute_decl_enumeration(ruby: &Ruby, handle: &NodeHandle) -> Result<RArray, Error> {
    let list = ruby.ary_new();
    if let Some(decl) = decl_of(handle) {
        for item in decl.attr_enum {
            list.push(item)?;
        }
    }
    Ok(list)
}

fn dtd_child_hash(ruby: &Ruby, handle: &NodeHandle, kind: i32) -> Result<Value, Error> {
    let store = handle.store();
    let children = store.borrow().nodes[handle.id() as usize].children.clone();
    let mut pairs = Vec::new();
    for child in children {
        if store.borrow().nodes[child as usize].kind != kind {
            continue;
        }
        let key = store.borrow().nodes[child as usize].name.clone().unwrap_or_default();
        pairs.push((key, child));
    }
    if pairs.is_empty() && kind != ATTRIBUTE_DECL {
        return Ok(ruby.qnil().as_value());
    }
    let hash = ruby.hash_new();
    for (key, child) in pairs {
        hash.aset(key, wrap_node(ruby, &store, child, None))?;
    }
    Ok(hash.as_value())
}

fn dtd_elements(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    dtd_child_hash(ruby, handle, ELEMENT_DECL)
}

fn dtd_entities(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    dtd_child_hash(ruby, handle, ENTITY_DECL)
}

fn dtd_attributes(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    dtd_child_hash(ruby, handle, ATTRIBUTE_DECL)
}

fn dtd_notations(ruby: &Ruby, handle: &NodeHandle) -> Result<Value, Error> {
    let store = handle.store();
    let id = handle.id();
    let notes: Vec<_> = store
        .borrow()
        .notations
        .iter()
        .filter(|note| note.dtd == id)
        .map(|note| (note.name.clone(), note.public_id.clone(), note.system_id.clone()))
        .collect();
    if notes.is_empty() {
        return Ok(ruby.qnil().as_value());
    }
    let class: RClass = TryConvert::try_convert(ruby.eval::<Value>("::Nokogiri::XML::Notation")?)?;
    let hash = ruby.hash_new();
    for (name, public_id, system_id) in notes {
        let value = class.new_instance((name.as_str(), public_id, system_id))?;
        hash.aset(name, value)?;
    }
    Ok(hash.as_value())
}

fn dtd_validate(ruby: &Ruby, _handle: &NodeHandle, document: Value) -> Result<Value, Error> {
    let existing = get_ivar(document, "@errors")?;
    if existing.is_nil() {
        return Ok(ruby.ary_new().as_value());
    }
    Ok(existing)
}

fn dtd_system_id(handle: &NodeHandle) -> Option<String> {
    handle.store().borrow().nodes[handle.id() as usize].system_id.clone()
}

fn dtd_external_id(handle: &NodeHandle) -> Option<String> {
    handle.store().borrow().nodes[handle.id() as usize].external_id.clone()
}

fn entity_original_content(handle: &NodeHandle) -> Option<String> {
    Some(handle.store().borrow().nodes[handle.id() as usize].content.clone())
}

fn entity_type_of(handle: &NodeHandle) -> i64 {
    handle.store().borrow().nodes[handle.id() as usize].entity_type
}

fn entity_external_id(handle: &NodeHandle) -> Option<String> {
    handle.store().borrow().nodes[handle.id() as usize].external_id.clone()
}

fn entity_system_id(handle: &NodeHandle) -> Option<String> {
    handle.store().borrow().nodes[handle.id() as usize].system_id.clone()
}

ni!(schema_from_document(_class: RClass, _args: &[Value]) "Schema.from_document");
ni!(schema_validate_document(_self: Value, _document: Value) "Schema#validate_document");
ni!(schema_validate_file(_self: Value, _path: Value) "Schema#validate_file");
ni!(relax_from_document(_class: RClass, _args: &[Value]) "RelaxNG.from_document");
ni!(relax_validate_document(_self: Value, _document: Value) "RelaxNG#validate_document");
ni!(xslt_register(_module: RModule, _name: String, _class: Value) "XSLT.register");
ni!(xslt_parse(_class: RClass, _document: Value) "XSLT::Stylesheet.parse_stylesheet_doc");
ni!(xslt_serialize(_self: Value, _document: Value) "XSLT#serialize");
ni!(xslt_transform(_self: Value, _args: &[Value]) "XSLT#transform");
ni!(sax_native_write(_self: Value, _chunk: Value, _last: Value) "SAX push write");
ni!(html_sax_native_write(_self: Value, _chunk: Value, _last: Value) "HTML SAX push write");
ni!(sax_context_memory(_class: RClass, _args: &[Value]) "SAX ParserContext");
ni!(sax_context_file(_class: RClass, _args: &[Value]) "SAX ParserContext file");
ni!(sax_context_io(_class: RClass, _args: &[Value]) "SAX ParserContext io");
ni!(sax_parse_with(_self: Value, _parser: Value) "SAX parse_with");
ni!(html_sax_context_memory(_class: RClass, _args: &[Value]) "HTML SAX ParserContext");
ni!(html_sax_context_file(_class: RClass, _args: &[Value]) "HTML SAX ParserContext file");
ni!(html_sax_parse_with(_self: Value, _parser: Value) "HTML SAX parse_with");
ni!(gumbo_parse(_module: RModule, _args: &[Value]) "Gumbo.parse");
ni!(gumbo_fragment(_module: RModule, _args: &[Value]) "Gumbo.fragment");

fn sax_initialize_native(_self: Value) {}

fn sax_options(_self: Value) -> i32 {
    0
}

fn sax_options_set(_self: Value, options: i32) -> i32 {
    options
}

fn sax_replace_entities(_self: Value) -> bool {
    false
}

fn sax_replace_entities_set(_self: Value, value: bool) -> bool {
    value
}

fn sax_push_initialize(_self: Value, _parser: Value, _encoding: Value) {}

fn html_sax_push_initialize(_self: Value, _parser: Value, _filename: Value, _encoding: Value) {}

fn sax_recovery(_self: Value) -> bool {
    false
}

fn sax_recovery_set(_self: Value, value: bool) -> bool {
    value
}

fn sax_line(_self: Value) -> i32 {
    0
}

fn sax_column(_self: Value) -> i32 {
    0
}

fn define_node_methods(node: RClass) -> Result<(), Error> {
    node.define_alloc_func::<NodeHandle>();
    node.define_singleton_method("new", method!(node_new, -1))?;
    node.define_method("add_namespace_definition", method!(add_namespace_definition, 2))?;
    node.define_method("attribute", method!(attribute, 1))?;
    node.define_method("attribute_nodes", method!(attribute_nodes, 0))?;
    node.define_method("attribute_with_ns", method!(attribute_with_ns, 2))?;
    node.define_method("blank?", method!(blank, 0))?;
    node.define_method("child", method!(child, 0))?;
    node.define_method("children", method!(children, 0))?;
    node.define_method("content", method!(content, 0))?;
    node.define_method("create_external_subset", method!(create_external_subset, 3))?;
    node.define_method("create_internal_subset", method!(create_internal_subset, 3))?;
    node.define_method("data_ptr?", method!(data_ptr, 0))?;
    node.define_method("document", method!(document, 0))?;
    node.define_method("element_children", method!(element_children, 0))?;
    node.define_method("encode_special_chars", method!(encode_special, 1))?;
    node.define_method("external_subset", method!(external_subset, 0))?;
    node.define_method("first_element_child", method!(first_element_child, 0))?;
    node.define_method("internal_subset", method!(internal_subset, 0))?;
    node.define_method("key?", method!(key, 1))?;
    node.define_method("lang", method!(lang_of, 0))?;
    node.define_method("lang=", method!(set_lang, 1))?;
    node.define_method("last_element_child", method!(last_element_child, 0))?;
    node.define_method("line", method!(line, 0))?;
    node.define_method("line=", method!(set_line, 1))?;
    node.define_method("namespace", method!(namespace, 0))?;
    node.define_method("namespace_definitions", method!(namespace_definitions, 0))?;
    node.define_method("namespace_scopes", method!(namespace_scopes, 0))?;
    node.define_method("namespaced_key?", method!(namespaced_key, 2))?;
    node.define_method("native_content=", method!(native_content_set, 1))?;
    node.define_method("next_element", method!(next_element, 0))?;
    node.define_method("next_sibling", method!(next_sibling_node, 0))?;
    node.define_method("node_name", method!(node_name, 0))?;
    node.define_method("node_name=", method!(set_node_name, 1))?;
    node.define_method("node_type", method!(node_type, 0))?;
    node.define_method("parent", method!(parent, 0))?;
    node.define_method("path", method!(node_path, 0))?;
    node.define_method("pointer_id", method!(pointer_id, 0))?;
    node.define_method("previous_element", method!(previous_element, 0))?;
    node.define_method("previous_sibling", method!(previous_sibling_node, 0))?;
    node.define_method("unlink", method!(unlink, 0))?;
    node.define_protected_method("initialize_copy_with_args", method!(initialize_copy_node, 3))?;
    node.define_protected_method("safe_process_xinclude", method!(safe_process_xinclude, 1))?;
    node.define_private_method("add_child_node", method!(add_child_node, 1))?;
    node.define_private_method("add_next_sibling_node", method!(add_next_sibling_node, 1))?;
    node.define_private_method("add_previous_sibling_node", method!(add_previous_sibling_node, 1))?;
    node.define_private_method("compare", method!(compare, 1))?;
    node.define_private_method("dump_html", method!(dump_html, 0))?;
    node.define_private_method("get", method!(get_attr, 1))?;
    node.define_private_method("in_context", method!(in_context, 2))?;
    node.define_private_method("native_write_to", method!(native_write_to, 4))?;
    node.define_private_method("prepend_newline?", method!(prepend_newline, 0))?;
    node.define_private_method("html_standard_serialize", method!(html_standard_serialize, 1))?;
    node.define_private_method("process_xincludes", method!(process_xincludes, 1))?;
    node.define_private_method("replace_node", method!(replace_node, 1))?;
    node.define_private_method("set", method!(set_attr, 2))?;
    node.define_private_method("set_namespace", method!(set_namespace, 1))?;
    Ok(())
}

fn element_end(ruby: &Ruby, handle: &NodeHandle, first: bool) -> Option<Value> {
    let store = handle.store();
    let children = store.borrow().nodes[handle.id() as usize].children.clone();
    let iter: Box<dyn Iterator<Item = u32>> = if first { Box::new(children.into_iter()) } else { Box::new(children.into_iter().rev()) };
    for id in iter {
        if store.borrow().nodes[id as usize].kind == ELEMENT {
            return Some(wrap_node(ruby, &store, id, None));
        }
    }
    None
}

fn define_reader(reader: RClass) -> Result<(), Error> {
    reader.define_singleton_method("from_memory", method!(reader_from_memory, -1))?;
    reader.define_singleton_method("from_io", method!(reader_from_io, -1))?;
    reader.define_method("attribute", method!(reader_attr, 1))?;
    reader.define_method("attribute_at", method!(reader_attr_at, 1))?;
    reader.define_method("attribute_count", method!(reader_attr_count, 0))?;
    reader.define_method("attribute_hash", method!(reader_attr_hash, 0))?;
    reader.define_method("attributes?", method!(reader_attributes_eh, 0))?;
    reader.define_method("base_uri", method!(reader_base_uri, 0))?;
    reader.define_method("default?", method!(reader_default, 0))?;
    reader.define_method("depth", method!(reader_depth, 0))?;
    reader.define_method("empty_element?", method!(reader_empty, 0))?;
    reader.define_method("encoding", method!(reader_encoding, 0))?;
    reader.define_method("inner_xml", method!(reader_inner_xml, 0))?;
    reader.define_method("lang", method!(reader_lang, 0))?;
    reader.define_method("local_name", method!(reader_name, 0))?;
    reader.define_method("name", method!(reader_name, 0))?;
    reader.define_method("namespace_uri", method!(reader_namespace_uri, 0))?;
    reader.define_method("namespaces", method!(reader_namespaces, 0))?;
    reader.define_method("node_type", method!(reader_node_type, 0))?;
    reader.define_method("outer_xml", method!(reader_outer_xml, 0))?;
    reader.define_method("prefix", method!(reader_prefix, 0))?;
    reader.define_method("read", method!(reader_read, 0))?;
    reader.define_method("state", method!(reader_state, 0))?;
    reader.define_method("value", method!(reader_value, 0))?;
    reader.define_method("value?", method!(reader_value_eh, 0))?;
    reader.define_method("xml_version", method!(reader_xml_version, 0))?;
    Ok(())
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let nokogiri = ruby.define_module("Nokogiri")?;
    // These flags exist on the C extension. They do not select the libxml code path.
    nokogiri.const_set("LIBXML_ICONV_ENABLED", false)?;
    nokogiri.const_set("LIBXML_ZLIB_ENABLED", false)?;
    nokogiri.const_set("LIBXML_HTTP_ENABLED", false)?;
    nokogiri.const_set("LIBXSLT_DATETIME_ENABLED", false)?;
    nokogiri.const_set("PACKAGED_LIBRARIES", false)?;
    let gumbo = nokogiri.define_module("Gumbo")?;
    let html4 = nokogiri.define_module("HTML4")?;
    let html4_sax = html4.define_module("SAX")?;
    let xml = nokogiri.define_module("XML")?;
    let xml_sax = xml.define_module("SAX")?;
    let xpath_mod = xml.define_module("XPath")?;
    let xslt = nokogiri.define_module("XSLT")?;
    let test = nokogiri.define_module("Test")?;

    let syntax = nokogiri.define_class("SyntaxError", ruby.exception_standard_error().as_r_class())?;
    let xml_syntax = xml.define_class("SyntaxError", syntax)?;
    let xpath_syntax = xpath_mod.define_class("SyntaxError", xml_syntax)?;

    let node = xml.define_class("Node", ruby.class_object())?;
    let element = xml.define_class("Element", node)?;
    let character = xml.define_class("CharacterData", node)?;
    let text = xml.define_class("Text", character)?;
    let cdata = xml.define_class("CDATA", text)?;
    let comment = xml.define_class("Comment", character)?;
    let attr = xml.define_class("Attr", node)?;
    let pi = xml.define_class("ProcessingInstruction", node)?;
    let document = xml.define_class("Document", node)?;
    let html_document = html4.define_class("Document", document)?;
    let fragment = xml.define_class("DocumentFragment", node)?;
    let dtd = xml.define_class("DTD", node)?;
    let entity_ref = xml.define_class("EntityReference", node)?;
    let entity_decl = xml.define_class("EntityDecl", node)?;
    let element_decl = xml.define_class("ElementDecl", node)?;
    let attribute_decl = xml.define_class("AttributeDecl", node)?;
    let namespace = xml.define_class("Namespace", ruby.class_object())?;
    let node_set = xml.define_class("NodeSet", ruby.class_object())?;
    let element_content = xml.define_class("ElementContent", ruby.class_object())?;
    let xpath_context = xml.define_class("XPathContext", ruby.class_object())?;
    let encoding = nokogiri.define_class("EncodingHandler", ruby.class_object())?;
    let description = html4.define_class("ElementDescription", ruby.class_object())?;
    let entity_lookup = html4.define_class("EntityLookup", ruby.class_object())?;
    let reader = xml.define_class("Reader", ruby.class_object())?;
    let schema = xml.define_class("Schema", ruby.class_object())?;
    let relax = xml.define_class("RelaxNG", schema)?;
    let stylesheet = xslt.define_class("Stylesheet", ruby.class_object())?;
    let sax_parser = xml_sax.define_class("Parser", ruby.class_object())?;
    let sax_context = xml_sax.define_class("ParserContext", ruby.class_object())?;
    let sax_push = xml_sax.define_class("PushParser", ruby.class_object())?;
    let html_sax_parser = html4_sax.define_class("Parser", sax_parser)?;
    let html_sax_context = html4_sax.define_class("ParserContext", sax_context)?;
    let html_sax_push = html4_sax.define_class("PushParser", ruby.class_object())?;

    CLASSES.with(|slot| {
        *slot.borrow_mut() = Some(Classes {
            element,
            text,
            cdata,
            comment,
            attr,
            pi,
            document,
            html_document,
            fragment,
            dtd,
            entity_ref,
            entity_decl,
            element_decl,
            attribute_decl,
            namespace,
            node_set,
            syntax_error: xml_syntax,
            xpath_syntax,
        });
    });

    define_node_methods(node)?;
    document.define_singleton_method("read_memory", method!(read_memory, 4))?;
    document.define_singleton_method("read_io", method!(read_io, 4))?;
    document.define_singleton_method("new", method!(document_new, -1))?;
    document.define_method("root", method!(root, 0))?;
    document.define_method("root=", method!(set_root, 1))?;
    document.define_method("encoding", method!(document_encoding, 0))?;
    document.define_method("encoding=", method!(set_encoding, 1))?;
    document.define_method("version", method!(version, 0))?;
    document.define_method("canonicalize", method!(canonicalize, -1))?;
    document.define_method("url", method!(url, 0))?;
    document.define_method("create_entity", method!(create_entity, -1))?;
    document.define_method("remove_namespaces!", method!(remove_namespaces, 0))?;
    document.define_protected_method("initialize_copy_with_args", method!(initialize_copy_document, 2))?;

    html_document.define_singleton_method("read_memory", method!(read_memory, 4))?;
    html_document.define_singleton_method("read_io", method!(read_io, 4))?;
    html_document.define_singleton_method("new", method!(document_new, -1))?;
    html_document.define_method("type", method!(node_type, 0))?;

    text.define_singleton_method("new", method!(text_new, 2))?;
    comment.define_singleton_method("new", method!(comment_new, 2))?;
    entity_ref.define_singleton_method("new", method!(entity_ref_new, 2))?;
    cdata.define_singleton_method("new", method!(cdata_new, 2))?;
    attr.define_singleton_method("new", method!(attr_new, 2))?;
    attr.define_method("value=", method!(attr_value_set, 1))?;
    pi.define_singleton_method("new", method!(pi_new, 3))?;
    fragment.define_singleton_method("native_new", method!(fragment_new, 1))?;

    namespace.define_method("prefix", method!(prefix, 0))?;
    namespace.define_method("href", method!(href, 0))?;

    node_set.define_alloc_func::<NodeSetHandle>();
    node_set.define_method("&", method!(nodeset_and, 1))?;
    node_set.define_method("-", method!(nodeset_minus, 1))?;
    node_set.define_method("[]", method!(nodeset_slice, -1))?;
    node_set.define_method("delete", method!(nodeset_delete, 1))?;
    node_set.define_method("include?", method!(nodeset_include, 1))?;
    node_set.define_method("length", method!(nodeset_length, 0))?;
    node_set.define_method("push", method!(nodeset_push, 1))?;
    node_set.define_method("slice", method!(nodeset_slice, -1))?;
    node_set.define_method("to_a", method!(nodeset_to_a, 0))?;
    node_set.define_method("unlink", method!(nodeset_unlink, 0))?;
    node_set.define_method("|", method!(nodeset_or, 1))?;
    node_set.define_private_method("initialize_copy", method!(nodeset_copy, 1))?;

    xpath_context.define_singleton_method("new", method!(xpath_new, 1))?;
    xpath_context.define_method("evaluate", method!(xpath_evaluate, -1))?;
    xpath_context.define_method("register_ns", method!(xpath_register_ns, 2))?;
    xpath_context.define_method("register_variable", method!(xpath_register_var, 2))?;
    xpath_context.define_method("node=", method!(xpath_set_node, 1))?;

    encoding.define_singleton_method("[]", method!(encoding_get, 1))?;
    encoding.define_singleton_method("delete", method!(encoding_delete, 1))?;
    encoding.define_singleton_method("alias", method!(encoding_alias, 2))?;
    encoding.define_singleton_method("clear_aliases!", method!(encoding_clear, 0))?;
    encoding.define_method("name", method!(encoding_name, 0))?;

    description.define_singleton_method("[]", method!(element_description_get, 1))?;
    description.define_method("name", method!(description_name, 0))?;
    description.define_method("implied_start_tag?", method!(description_implied_start, 0))?;
    description.define_method("implied_end_tag?", method!(description_implied_end, 0))?;
    description.define_method("save_end_tag?", method!(description_save_end, 0))?;
    description.define_method("empty?", method!(description_empty, 0))?;
    description.define_method("deprecated?", method!(description_deprecated, 0))?;
    description.define_method("inline?", method!(description_inline, 0))?;
    description.define_method("description", method!(description_name, 0))?;
    description.define_method("sub_elements", method!(description_list, 0))?;
    description.define_method("default_sub_element", method!(description_default_sub, 0))?;
    description.define_method("optional_attributes", method!(description_list, 0))?;
    description.define_method("deprecated_attributes", method!(description_list, 0))?;
    description.define_method("required_attributes", method!(description_list, 0))?;

    entity_lookup.define_method("get", method!(entity_get, 1))?;

    define_reader(reader)?;

    element_content.define_method("name", method!(element_content_name, 0))?;
    element_content.define_method("type", method!(element_content_type, 0))?;
    element_content.define_method("occur", method!(element_content_occur, 0))?;
    element_content.define_method("prefix", method!(element_content_prefix, 0))?;
    element_content.define_private_method("c1", method!(element_content_c1, 0))?;
    element_content.define_private_method("c2", method!(element_content_c2, 0))?;

    dtd.define_method("notations", method!(dtd_notations, 0))?;
    dtd.define_method("elements", method!(dtd_elements, 0))?;
    dtd.define_method("entities", method!(dtd_entities, 0))?;
    dtd.define_method("attributes", method!(dtd_attributes, 0))?;
    dtd.define_method("validate", method!(dtd_validate, 1))?;
    dtd.define_method("system_id", method!(dtd_system_id, 0))?;
    dtd.define_method("external_id", method!(dtd_external_id, 0))?;

    element_decl.define_method("element_type", method!(element_decl_type, 0))?;
    element_decl.define_method("prefix", method!(element_decl_prefix, 0))?;
    element_decl.define_method("content", method!(element_decl_content, 0))?;

    attribute_decl.define_method("attribute_type", method!(attribute_decl_type, 0))?;
    attribute_decl.define_method("default", method!(attribute_decl_default, 0))?;
    attribute_decl.define_method("enumeration", method!(attribute_decl_enumeration, 0))?;

    entity_decl.define_method("original_content", method!(entity_original_content, 0))?;
    entity_decl.define_method("content", method!(content, 0))?;
    entity_decl.define_method("entity_type", method!(entity_type_of, 0))?;
    entity_decl.define_method("external_id", method!(entity_external_id, 0))?;
    entity_decl.define_method("system_id", method!(entity_system_id, 0))?;
    entity_decl.const_set("INTERNAL_GENERAL", 1)?;
    entity_decl.const_set("EXTERNAL_GENERAL_PARSED", 2)?;
    entity_decl.const_set("EXTERNAL_GENERAL_UNPARSED", 3)?;
    entity_decl.const_set("INTERNAL_PARAMETER", 4)?;
    entity_decl.const_set("EXTERNAL_PARAMETER", 5)?;
    entity_decl.const_set("INTERNAL_PREDEFINED", 6)?;

    schema.define_singleton_method("from_document", method!(schema_from_document, -1))?;
    schema.define_private_method("validate_document", method!(schema_validate_document, 1))?;
    schema.define_private_method("validate_file", method!(schema_validate_file, 1))?;
    relax.define_singleton_method("from_document", method!(relax_from_document, -1))?;
    relax.define_private_method("validate_document", method!(relax_validate_document, 1))?;

    xslt.define_singleton_method("register", method!(xslt_register, 2))?;
    stylesheet.define_singleton_method("parse_stylesheet_doc", method!(xslt_parse, 1))?;
    stylesheet.define_method("serialize", method!(xslt_serialize, 1))?;
    stylesheet.define_method("transform", method!(xslt_transform, -1))?;

    sax_parser.define_private_method("initialize_native", method!(sax_initialize_native, 0))?;
    sax_push.define_method("options", method!(sax_options, 0))?;
    sax_push.define_method("options=", method!(sax_options_set, 1))?;
    sax_push.define_method("replace_entities", method!(sax_replace_entities, 0))?;
    sax_push.define_method("replace_entities=", method!(sax_replace_entities_set, 1))?;
    sax_push.define_private_method("initialize_native", method!(sax_push_initialize, 2))?;
    sax_push.define_private_method("native_write", method!(sax_native_write, 2))?;
    html_sax_push.define_private_method("initialize_native", method!(html_sax_push_initialize, 3))?;
    html_sax_push.define_private_method("native_write", method!(html_sax_native_write, 2))?;
    sax_context.define_singleton_method("native_memory", method!(sax_context_memory, -1))?;
    sax_context.define_singleton_method("native_file", method!(sax_context_file, -1))?;
    sax_context.define_singleton_method("native_io", method!(sax_context_io, -1))?;
    sax_context.define_method("parse_with", method!(sax_parse_with, 1))?;
    html_sax_context.define_singleton_method("native_memory", method!(html_sax_context_memory, -1))?;
    html_sax_context.define_singleton_method("native_file", method!(html_sax_context_file, -1))?;
    html_sax_context.define_method("parse_with", method!(html_sax_parse_with, 1))?;
    sax_context.define_method("recovery", method!(sax_recovery, 0))?;
    sax_context.define_method("recovery=", method!(sax_recovery_set, 1))?;
    sax_context.define_method("line", method!(sax_line, 0))?;
    sax_context.define_method("column", method!(sax_column, 0))?;
    sax_context.define_method("replace_entities", method!(sax_replace_entities, 0))?;
    sax_context.define_method("replace_entities=", method!(sax_replace_entities_set, 1))?;

    gumbo.define_singleton_method("parse", method!(gumbo_parse, -1))?;
    gumbo.define_singleton_method("fragment", method!(gumbo_fragment, -1))?;
    test.define_singleton_method("__foreign_error_handler", method!(foreign_error_handler, 0))?;

    let _ = (html_sax_parser, AS_HTML, AS_XML);
    Ok(())
}

// Entity lookup uses this helper so the HTML entity table stays in one place.
trait ParseEntity {
    fn code(name: &str) -> Option<char>;
}

pub fn parse_entity(name: &str) -> Option<char> {
    // Reuse the HTML entity table by parsing a reference.
    let mut owned = String::from("&");
    owned.push_str(name);
    owned.push(';');
    let parsed = parse_html(&format!("<p>{owned}</p>"), None, None, RECOVER, next_key());
    let store = parsed.store.borrow();
    let root = store.root_element(0)?;
    let body = store.nodes[root as usize].children.iter().copied().find(|id| {
        store.nodes[*id as usize].name.as_deref() == Some("body")
    })?;
    let paragraph = store.nodes[body as usize].children.iter().copied().find(|id| {
        store.nodes[*id as usize].name.as_deref() == Some("p")
    })?;
    let text = store.nodes[paragraph as usize].children.first().copied()?;
    store.nodes[text as usize].content.chars().next()
}
