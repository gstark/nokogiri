//! SAX bridge. xmloxide reports XML events. HTML uses an HTML5 tree walk so
//! implied html, head, and body tags are present. Push parsing reparses the
//! buffer and emits only the new suffix of events.

use std::cell::RefCell;

use magnus::error::Error;
use magnus::value::ReprValue;
use magnus::typed_data::DataTypeFunctions;
use magnus::{ArgList, Exception, IntoValue, RClass, RModule, Ruby, TryConvert, Value, prelude::*};
use xmloxide::encoding::{decode_to_utf8, transcode};
use xmloxide::error::ErrorSeverity;
use xmloxide::html5::parse_html5;
use xmloxide::parser::{ParseOptions, parse_str_with_options};
use xmloxide::sax::{SaxHandler, parse_sax};
use xmloxide::tree::{Document, NodeId, NodeKind};

const RECOVER: i32 = 1 << 0;

#[derive(Clone, Debug, PartialEq, Eq)]
enum Ev {
    XmlDecl(String, Option<String>, Option<String>),
    StartDocument,
    EndDocument,
    StartNs {
        local: String,
        attrs: Vec<Attr>,
        prefix: Option<String>,
        uri: Option<String>,
        ns: Vec<(Option<String>, String)>,
    },
    EndNs {
        local: String,
        prefix: Option<String>,
        uri: Option<String>,
    },
    Start {
        name: String,
        attrs: Vec<(String, Option<String>)>,
    },
    End {
        name: String,
    },
    Characters(String),
    Comment(String),
    Cdata(String),
    Pi(String, Option<String>),
    Reference(String, Option<String>),
}

struct Parsed {
    events: Vec<Ev>,
    errors: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Attr {
    local: String,
    prefix: Option<String>,
    uri: Option<String>,
    value: String,
}

struct PushInner {
    bytes: Vec<u8>,
    events: Vec<Ev>,
    last_error: Option<String>,
    html: bool,
    encoding: Option<String>,
}

#[derive(magnus::TypedData)]
#[magnus(class = "Nokogiri::XML::SAX::ParserState", free_immediately)]
struct ParserState {
    inner: RefCell<PushInner>,
}

unsafe impl Send for ParserState {}

impl DataTypeFunctions for ParserState {}

struct Collector {
    events: Vec<Ev>,
}

impl SaxHandler for Collector {
    fn start_document(&mut self) {
        self.events.push(Ev::StartDocument);
    }

    fn end_document(&mut self) {
        self.events.push(Ev::EndDocument);
    }

    fn start_element(
        &mut self,
        local_name: &str,
        prefix: Option<&str>,
        namespace: Option<&str>,
        attributes: &[(String, String, Option<String>, Option<String>)],
    ) {
        let mut attrs = Vec::new();
        let mut ns = Vec::new();
        for (local, value, attr_prefix, attr_ns) in attributes {
            if attr_prefix.as_deref() == Some("xmlns") {
                ns.push((Some(local.clone()), value.clone()));
            } else if attr_prefix.is_none() && local == "xmlns" {
                ns.push((None, value.clone()));
            } else {
                attrs.push(Attr {
                    local: local.clone(),
                    prefix: attr_prefix.clone(),
                    uri: attr_ns.clone(),
                    value: value.clone(),
                });
            }
        }
        self.events.push(Ev::StartNs {
            local: local_name.to_string(),
            attrs,
            prefix: prefix.map(str::to_string),
            uri: namespace.map(str::to_string),
            ns,
        });
    }

    fn end_element(&mut self, local_name: &str, prefix: Option<&str>, namespace: Option<&str>) {
        self.events.push(Ev::EndNs {
            local: local_name.to_string(),
            prefix: prefix.map(str::to_string),
            uri: namespace.map(str::to_string),
        });
    }

    fn characters(&mut self, content: &str) {
        self.events.push(Ev::Characters(content.to_string()));
    }

    fn cdata(&mut self, content: &str) {
        self.events.push(Ev::Cdata(content.to_string()));
    }

    fn comment(&mut self, content: &str) {
        self.events.push(Ev::Comment(content.to_string()));
    }

    fn processing_instruction(&mut self, target: &str, data: Option<&str>) {
        self.events.push(Ev::Pi(target.to_string(), data.map(str::to_string)));
    }
}

pub fn sax_context_memory(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    let input = arg(ruby, args, 0)?;
    expect_string(ruby, input)?;
    let encoding = args.get(1).copied().unwrap_or_else(|| ruby.qnil().as_value());
    check_encoding(ruby, encoding)?;
    let bytes = bytes_of(input)?;
    if bytes.is_empty() {
        return Err(Error::new(ruby.exception_runtime_error(), "input string cannot be empty"));
    }
    make_context(ruby, class, "memory", Some(input), None, encoding)
}

pub fn sax_context_file(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    let path = arg(ruby, args, 0)?;
    let encoding = args.get(1).copied().unwrap_or_else(|| ruby.qnil().as_value());
    check_encoding(ruby, encoding)?;
    expect_string(ruby, path)?;
    let text: String = TryConvert::try_convert(path)?;
    make_context(ruby, class, "file", None, Some(text), encoding)
}

pub fn sax_context_io(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    let input = arg(ruby, args, 0)?;
    if !input.respond_to("read", false)? {
        return Err(Error::new(ruby.exception_type_error(), "argument expected to respond to :read"));
    }
    let encoding = args.get(1).copied().unwrap_or_else(|| ruby.qnil().as_value());
    check_encoding(ruby, encoding)?;
    make_context(ruby, class, "io", Some(input), None, encoding)
}

pub fn html_sax_context_memory(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    sax_context_memory(ruby, class, args)
}

pub fn html_sax_context_file(ruby: &Ruby, class: RClass, args: &[Value]) -> Result<Value, Error> {
    sax_context_file(ruby, class, args)
}

pub fn sax_parse_with(ruby: &Ruby, context: Value, parser: Value) -> Result<Value, Error> {
    parse_context(ruby, context, parser, false)
}

pub fn html_sax_parse_with(ruby: &Ruby, context: Value, parser: Value) -> Result<Value, Error> {
    parse_context(ruby, context, parser, true)
}

pub fn sax_push_initialize(ruby: &Ruby, this: Value, _parser: Value, _filename: Value) -> Result<(), Error> {
    install_push(ruby, this, false, None)
}

pub fn html_sax_push_initialize(ruby: &Ruby, this: Value, _parser: Value, _filename: Value, encoding: Value) -> Result<(), Error> {
    install_push(ruby, this, true, encoding_label(encoding))
}

pub fn sax_native_write(ruby: &Ruby, this: Value, chunk: Value, last: Value) -> Result<Value, Error> {
    push_write(ruby, this, chunk, last, false)
}

pub fn html_sax_native_write(ruby: &Ruby, this: Value, chunk: Value, last: Value) -> Result<Value, Error> {
    push_write(ruby, this, chunk, last, true)
}

pub fn sax_options(this: Value) -> i32 {
    ivar_i32(this, "@_sax_options").unwrap_or(0)
}

pub fn sax_options_set(this: Value, options: i32) -> i32 {
    let _ = set_ivar(this, "@_sax_options", options);
    options
}

pub fn sax_replace_entities(this: Value) -> bool {
    if is_push(this) {
        return true;
    }
    ivar_bool(this, "@_sax_replace_entities").unwrap_or(false)
}

pub fn sax_replace_entities_set(this: Value, value: bool) -> bool {
    if is_push(this) {
        return true;
    }
    let _ = set_ivar(this, "@_sax_replace_entities", value);
    value
}

pub fn sax_recovery(this: Value) -> bool {
    ivar_bool(this, "@_sax_recovery").unwrap_or(false)
}

pub fn sax_recovery_set(this: Value, value: bool) -> bool {
    let _ = set_ivar(this, "@_sax_recovery", value);
    value
}

pub fn sax_line(this: Value) -> i32 {
    ivar_i32(this, "@_sax_line").unwrap_or(0)
}

pub fn sax_column(this: Value) -> i32 {
    ivar_i32(this, "@_sax_column").unwrap_or(0)
}

fn parse_context(ruby: &Ruby, context: Value, parser: Value, html_method: bool) -> Result<Value, Error> {
    expect_parser(ruby, parser)?;
    let document = get_ivar(parser, "@document")?;
    let html = html_method || ivar_bool(context, "@_sax_html").unwrap_or(false);
    let bytes = context_bytes(context)?;
    let encoding = ivar_string(context, "@_sax_encoding");
    let recover = ivar_bool(context, "@_sax_recovery").unwrap_or(false);
    let replace = ivar_bool(context, "@_sax_replace_entities").unwrap_or(false);
    let text = decode_bytes(&bytes, encoding.as_deref(), html).unwrap_or_else(|message| {
        let _ = call(document, "error", (message.as_str(),));
        String::from_utf8_lossy(&bytes).into_owned()
    });
    let parsed = collect(&text, html, recover, replace);
    let mut cursor = 0usize;
    emit(ruby, document, Some(context), &text, &mut cursor, &parsed.events)?;
    for message in &parsed.errors {
        call(document, "error", (message.as_str(),))?;
    }
    Ok(ruby.qnil().as_value())
}

fn push_write(ruby: &Ruby, this: Value, chunk: Value, last: Value, html_default: bool) -> Result<Value, Error> {
    let state_value = ensure_push(ruby, this, html_default)?;
    let state: &ParserState = TryConvert::try_convert(state_value)?;
    {
        let inner = state.inner.borrow();
        if let Some(message) = inner.last_error.clone() {
            return Err(syntax_error(ruby, &message)?);
        }
    }
    let last = truthy(last);
    if !chunk.is_nil() {
        let extra = bytes_of(chunk)?;
        state.inner.borrow_mut().bytes.extend(extra);
    }
    let (bytes, html, encoding, previous) = {
        let inner = state.inner.borrow();
        (inner.bytes.clone(), inner.html, inner.encoding.clone(), inner.events.clone())
    };
    let recover = sax_options(this) & RECOVER != 0;
    if bytes.iter().all(|byte| byte.is_ascii_whitespace()) {
        if last && recover {
            let document = get_ivar(this, "@document")?;
            call(document, "end_document", ())?;
        } else if last {
            let message = "Document is empty".to_string();
            state.inner.borrow_mut().last_error = Some(message.clone());
            return Err(syntax_error(ruby, &message)?);
        }
        return Ok(this);
    }
    let text = decode_bytes(&bytes, encoding.as_deref(), html).unwrap_or_else(|_| String::from_utf8_lossy(&bytes).into_owned());
    let parsed = collect(&text, html, recover, true);
    let delta = diff_events(&previous, &parsed.events);
    let document = get_ivar(this, "@document")?;
    let mut cursor = 0usize;
    if let Err(error) = emit(ruby, document, None, &text, &mut cursor, &delta) {
        return Err(error);
    }
    state.inner.borrow_mut().events = parsed.events.iter().filter(|event| !matches!(event, Ev::EndDocument)).cloned().collect();
    if let Some(message) = parsed.errors.first().cloned() {
        let incomplete = parsed.errors.iter().all(|item| is_incomplete(item));
        if recover || (incomplete && !last) {
            if recover {
                let document = get_ivar(this, "@document")?;
                for item in &parsed.errors {
                    call(document, "error", (item.as_str(),))?;
                }
            }
        } else {
            let document = get_ivar(this, "@document")?;
            for item in &parsed.errors {
                call(document, "error", (item.as_str(),))?;
            }
            state.inner.borrow_mut().last_error = Some(message.clone());
            return Err(syntax_error(ruby, &message)?);
        }
    }
    if last {
        let document = get_ivar(this, "@document")?;
        call(document, "end_document", ())?;
    }
    Ok(this)
}

fn collect(text: &str, html: bool, recover: bool, replace_entities: bool) -> Parsed {
    if html {
        let mut events = vec![Ev::StartDocument];
        if let Ok(doc) = parse_html5(text) {
            walk_html(&doc, doc.root(), &mut events);
        }
        events.push(Ev::EndDocument);
        return Parsed { events, errors: Vec::new() };
    }
    let (rewritten, refs) = rewrite_entities(text, replace_entities);
    let mut collector = Collector { events: Vec::new() };
    let options = ParseOptions::default().recover(recover);
    let errors = match parse_sax(&rewritten, &options, &mut collector) {
        Ok(()) => Vec::new(),
        // Events stay on this parse. The error list matches the recover DOM
        // parser, which keeps going and records every diagnostic.
        Err(error) => recover_messages(&rewritten).unwrap_or_else(|| sax_failure_messages(&error)),
    };
    if let Some((version, encoding, standalone)) = xml_decl(&rewritten) {
        collector.events.insert(0, Ev::XmlDecl(version, encoding, standalone));
    }
    if !refs.is_empty() {
        let mut with_refs = Vec::new();
        for event in collector.events {
            if matches!(event, Ev::EndDocument) {
                for (name, content) in &refs {
                    with_refs.push(Ev::Reference(name.clone(), content.clone()));
                }
            }
            with_refs.push(event);
        }
        if !with_refs.iter().any(|event| matches!(event, Ev::EndDocument)) {
            for (name, content) in refs {
                with_refs.push(Ev::Reference(name, content));
            }
        }
        collector.events = with_refs;
    }
    Parsed { events: collector.events, errors }
}

fn walk_html(doc: &Document, id: NodeId, events: &mut Vec<Ev>) {
    for child in doc.children(id) {
        match &doc.node(child).kind {
            NodeKind::Element { name, attributes, .. } => {
                let attrs = attributes.iter().map(|attr| {
                    let value = if attr.value.is_empty() { None } else { Some(attr.value.clone()) };
                    (attr.name.to_ascii_lowercase(), value)
                }).collect();
                let name = name.to_ascii_lowercase();
                events.push(Ev::Start { name: name.clone(), attrs });
                walk_html(doc, child, events);
                events.push(Ev::End { name });
            }
            NodeKind::Text { content } | NodeKind::CData { content } => {
                events.push(Ev::Characters(content.clone()));
            }
            NodeKind::Comment { content } => events.push(Ev::Comment(content.clone())),
            NodeKind::ProcessingInstruction { target, data } => {
                events.push(Ev::Pi(target.clone(), data.clone()));
            }
            NodeKind::Document => walk_html(doc, child, events),
            _ => {}
        }
    }
}

fn emit(ruby: &Ruby, document: Value, context: Option<Value>, source: &str, cursor: &mut usize, events: &[Ev]) -> Result<(), Error> {
    for event in events {
        match event {
            Ev::XmlDecl(version, encoding, standalone) => {
                call(document, "xmldecl", (version.as_str(), opt(ruby, encoding), opt(ruby, standalone)))?;
            }
            Ev::StartDocument => call(document, "start_document", ())?,
            Ev::EndDocument => call(document, "end_document", ())?,
            Ev::StartNs { local, attrs, prefix, uri, ns } => {
                if let Some(context) = context {
                    if let Some((line, column, next)) = locate_start(source, *cursor, local, prefix.as_deref()) {
                        let _ = set_ivar(context, "@_sax_line", line);
                        let _ = set_ivar(context, "@_sax_column", column);
                        *cursor = next;
                    }
                }
                let list = ruby.ary_new();
                let class = attribute_class(ruby)?;
                for attr in attrs {
                    let object = class.new_instance((
                        attr.local.as_str(),
                        opt(ruby, &attr.prefix),
                        opt(ruby, &attr.uri),
                        attr.value.as_str(),
                    ))?;
                    list.push(object)?;
                }
                let namespaces = ruby.ary_new();
                for (prefix, href) in ns {
                    let pair = ruby.ary_new();
                    pair.push(opt(ruby, prefix))?;
                    pair.push(href.as_str())?;
                    namespaces.push(pair)?;
                }
                call(document, "start_element_namespace", (local.as_str(), list, opt(ruby, prefix), opt(ruby, uri), namespaces))?;
            }
            Ev::EndNs { local, prefix, uri } => {
                call(document, "end_element_namespace", (local.as_str(), opt(ruby, prefix), opt(ruby, uri)))?;
            }
            Ev::Start { name, attrs } => {
                let list = ruby.ary_new();
                for (key, value) in attrs {
                    let pair = ruby.ary_new();
                    pair.push(key.as_str())?;
                    match value {
                        Some(text) => pair.push(text.as_str())?,
                        None => pair.push(ruby.qnil().as_value())?,
                    }
                    list.push(pair)?;
                }
                call(document, "start_element", (name.as_str(), list))?;
            }
            Ev::End { name } => call(document, "end_element", (name.as_str(),))?,
            Ev::Characters(text) => call(document, "characters", (text.as_str(),))?,
            Ev::Comment(text) => call(document, "comment", (text.as_str(),))?,
            Ev::Cdata(text) => call(document, "cdata_block", (text.as_str(),))?,
            Ev::Pi(name, data) => call(document, "processing_instruction", (name.as_str(), opt(ruby, data)))?,
            Ev::Reference(name, content) => call(document, "reference", (name.as_str(), opt(ruby, content)))?,
        }
    }
    Ok(())
}

fn diff_events(old: &[Ev], new: &[Ev]) -> Vec<Ev> {
    let old: Vec<&Ev> = old.iter().filter(|event| !matches!(event, Ev::EndDocument)).collect();
    let new: Vec<&Ev> = new.iter().filter(|event| !matches!(event, Ev::EndDocument)).collect();
    let mut index = 0;
    let mut out = Vec::new();
    while index < old.len() && index < new.len() {
        match (old[index], new[index]) {
            (Ev::Characters(before), Ev::Characters(after)) if after.starts_with(before) && after != before => {
                out.push(Ev::Characters(after[before.len()..].to_string()));
                index += 1;
                break;
            }
            (left, right) if left == right => index += 1,
            _ => break,
        }
    }
    out.extend(new[index..].iter().map(|event| (*event).clone()));
    out
}

fn is_incomplete(message: &str) -> bool {
    message.contains("unexpected end of input") || message.contains("expected name, found end of input")
}

fn locate_start(source: &str, cursor: usize, local: &str, prefix: Option<&str>) -> Option<(i32, i32, usize)> {
    let needle = match prefix {
        Some(prefix) => format!("<{prefix}:{local}"),
        None => format!("<{local}"),
    };
    let bytes = source.as_bytes();
    let mut from = cursor.min(bytes.len());
    let found = loop {
        let rest = source.get(from..)?;
        let offset = rest.find(&needle)?;
        let at = from + offset;
        let after = at + needle.len();
        let boundary = bytes.get(after).is_none_or(|byte| !is_name_byte(*byte));
        if boundary {
            break at;
        }
        from = at + 1;
    };
    let mut index = found + needle.len();
    let mut quote = 0u8;
    while index < bytes.len() {
        let byte = bytes[index];
        if quote == 0 && (byte == b'"' || byte == b'\'') {
            quote = byte;
        } else if quote != 0 && byte == quote {
            quote = 0;
        } else if quote == 0 && byte == b'>' {
            break;
        }
        index += 1;
    }
    let (line, column) = line_col(source, index.min(bytes.len().saturating_sub(1)));
    Some((line, column, (index + 1).min(bytes.len())))
}

fn line_col(source: &str, byte_pos: usize) -> (i32, i32) {
    let mut line = 1i32;
    let mut column = 1i32;
    for (index, ch) in source.char_indices() {
        if index == byte_pos {
            return (line, column);
        }
        if ch == '\n' {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    (line, column)
}

fn xml_decl(input: &str) -> Option<(String, Option<String>, Option<String>)> {
    let trimmed = input.trim_start();
    if !trimmed.starts_with("<?xml") {
        return None;
    }
    let end = trimmed.find("?>")?;
    let body = &trimmed[..end];
    let version = decl_attr(body, "version")?;
    Some((version, decl_attr(body, "encoding"), decl_attr(body, "standalone")))
}

fn decl_attr(body: &str, name: &str) -> Option<String> {
    let at = body.find(name)?;
    let rest = body[at + name.len()..].trim_start();
    let rest = rest.strip_prefix('=')?.trim_start();
    let quote = rest.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let rest = &rest[1..];
    let end = rest.find(quote)?;
    Some(rest[..end].to_string())
}

#[derive(Clone)]
enum EntityKind {
    Internal(String),
    External(String),
}

struct Decl {
    name: String,
    kind: EntityKind,
}

fn rewrite_entities(input: &str, replace: bool) -> (String, Vec<(String, Option<String>)>) {
    let decls = entity_decls(input);
    if decls.is_empty() && !input.contains('&') {
        return (input.to_string(), Vec::new());
    }
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut refs = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'&' {
            if let Some((name, end)) = read_ref(input, index) {
                if name.starts_with('#') || is_builtin(&name) {
                    out.push_str(&input[index..end]);
                } else if let Some(decl) = decls.iter().find(|decl| decl.name == name) {
                    match &decl.kind {
                        EntityKind::Internal(value) => {
                            out.push_str(&input[index..end]);
                            if !replace {
                                refs.push((name, Some(value.clone())));
                            }
                        }
                        EntityKind::External(system) => {
                            if replace {
                                if let Some(text) = load_external(system) {
                                    out.push_str(&xml_escape(&text));
                                }
                            } else {
                                refs.push((name, None));
                            }
                        }
                    }
                } else {
                    out.push_str(&input[index..end]);
                    if !replace {
                        refs.push((name, None));
                    }
                }
                index = end;
                continue;
            }
        }
        let ch = input[index..].chars().next().unwrap_or('\u{FFFD}');
        out.push(ch);
        index += ch.len_utf8();
    }
    (out, refs)
}

fn entity_decls(input: &str) -> Vec<Decl> {
    let bytes = input.as_bytes();
    let mut index = 0;
    let mut decls = Vec::new();
    while index + 9 < bytes.len() {
        if bytes[index..].starts_with(b"<!ENTITY") {
            index += 8;
            index = skip_ws(bytes, index);
            let Some((name, next)) = read_name(input, index) else { break };
            index = skip_ws(bytes, next);
            if input[index..].starts_with("SYSTEM") {
                index = skip_ws(bytes, index + 6);
                if let Some((system, next)) = read_quoted(input, index) {
                    decls.push(Decl { name, kind: EntityKind::External(system) });
                    index = next;
                    continue;
                }
            } else if input[index..].starts_with("PUBLIC") {
                index = skip_ws(bytes, index + 6);
                if let Some((_, next)) = read_quoted(input, index) {
                    index = skip_ws(bytes, next);
                    if let Some((system, next)) = read_quoted(input, index) {
                        decls.push(Decl { name, kind: EntityKind::External(system) });
                        index = next;
                        continue;
                    }
                }
            } else if let Some((value, next)) = read_quoted(input, index) {
                decls.push(Decl { name, kind: EntityKind::Internal(value) });
                index = next;
                continue;
            }
        }
        index += 1;
    }
    decls
}

fn read_ref(input: &str, start: usize) -> Option<(String, usize)> {
    let bytes = input.as_bytes();
    if bytes.get(start) != Some(&b'&') {
        return None;
    }
    let mut index = start + 1;
    if bytes.get(index) == Some(&b'#') {
        index += 1;
        while index < bytes.len() && bytes[index] != b';' {
            index += 1;
        }
        if index >= bytes.len() {
            return None;
        }
        return Some((input[start + 1..index].to_string(), index + 1));
    }
    let name_at = index;
    while index < bytes.len() && is_name_byte(bytes[index]) {
        index += 1;
    }
    if index == name_at || bytes.get(index) != Some(&b';') {
        return None;
    }
    Some((input[name_at..index].to_string(), index + 1))
}

fn read_name(input: &str, start: usize) -> Option<(String, usize)> {
    let bytes = input.as_bytes();
    let mut index = start;
    if index >= bytes.len() || !is_name_start(bytes[index]) {
        return None;
    }
    index += 1;
    while index < bytes.len() && is_name_byte(bytes[index]) {
        index += 1;
    }
    Some((input[start..index].to_string(), index))
}

fn read_quoted(input: &str, start: usize) -> Option<(String, usize)> {
    let bytes = input.as_bytes();
    let quote = *bytes.get(start)?;
    if quote != b'"' && quote != b'\'' {
        return None;
    }
    let mut index = start + 1;
    while index < bytes.len() && bytes[index] != quote {
        index += 1;
    }
    if index >= bytes.len() {
        return None;
    }
    Some((input[start + 1..index].to_string(), index + 1))
}

fn skip_ws(bytes: &[u8], mut index: usize) -> usize {
    while index < bytes.len() && bytes[index].is_ascii_whitespace() {
        index += 1;
    }
    index
}

fn is_name_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_' || byte == b':'
}

fn is_name_byte(byte: u8) -> bool {
    is_name_start(byte) || byte.is_ascii_digit() || byte == b'-' || byte == b'.'
}

fn is_builtin(name: &str) -> bool {
    matches!(name, "amp" | "lt" | "gt" | "apos" | "quot")
}

fn load_external(system: &str) -> Option<String> {
    let path = if let Some(rest) = system.strip_prefix("file://") {
        rest.to_string()
    } else if system.contains("://") {
        return None;
    } else {
        system.to_string()
    };
    let bytes = std::fs::read(path).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn decode_bytes(bytes: &[u8], encoding: Option<&str>, html: bool) -> Result<String, String> {
    if let Some(encoding) = encoding {
        if encoding.eq_ignore_ascii_case("UTF-8") || encoding.eq_ignore_ascii_case("ASCII") {
            return String::from_utf8(bytes.to_vec()).or_else(|_| {
                if html {
                    Ok(String::from_utf8_lossy(bytes).into_owned())
                } else {
                    Err(format!("Invalid byte sequence in encoding {encoding}"))
                }
            });
        }
        return transcode(bytes, encoding).map_err(|error| error.to_string());
    }
    if html {
        if let Some(charset) = html_meta_charset(bytes) {
            if let Ok(text) = transcode(bytes, &charset) {
                return Ok(text);
            }
        }
        return Ok(String::from_utf8(bytes.to_vec()).unwrap_or_else(|_| String::from_utf8_lossy(bytes).into_owned()));
    }
    decode_to_utf8(bytes).map_err(|error| error.to_string())
}

fn html_meta_charset(bytes: &[u8]) -> Option<String> {
    let window = &bytes[..bytes.len().min(1024)];
    let needle = b"charset";
    let mut index = 0;
    while index + needle.len() < window.len() {
        if window[index..].len() >= needle.len()
            && window[index..index + needle.len()].eq_ignore_ascii_case(needle)
        {
            let mut cursor = index + needle.len();
            while cursor < window.len() && window[cursor].is_ascii_whitespace() {
                cursor += 1;
            }
            if cursor < window.len() && window[cursor] == b'=' {
                cursor += 1;
                while cursor < window.len() && window[cursor].is_ascii_whitespace() {
                    cursor += 1;
                }
                if cursor < window.len() && (window[cursor] == b'"' || window[cursor] == b'\'') {
                    cursor += 1;
                }
                let start = cursor;
                while cursor < window.len()
                    && (window[cursor].is_ascii_alphanumeric()
                        || matches!(window[cursor], b'-' | b'_' | b'.'))
                {
                    cursor += 1;
                }
                if cursor > start {
                    return Some(String::from_utf8_lossy(&window[start..cursor]).into_owned());
                }
            }
        }
        index += 1;
    }
    None
}

fn make_context(_ruby: &Ruby, class: RClass, kind: &str, input: Option<Value>, path: Option<String>, encoding: Value) -> Result<Value, Error> {
    let context: Value = class.funcall("allocate", ())?;
    set_ivar(context, "@_sax_kind", kind)?;
    set_ivar(context, "@_sax_html", class_name(&class).contains("HTML"))?;
    set_ivar(context, "@_sax_recovery", false)?;
    set_ivar(context, "@_sax_replace_entities", false)?;
    set_ivar(context, "@_sax_line", 0)?;
    set_ivar(context, "@_sax_column", 0)?;
    if let Some(input) = input {
        set_ivar(context, "@input", input)?;
    }
    if let Some(path) = path {
        set_ivar(context, "@_sax_path", path)?;
    }
    if let Some(name) = encoding_label(encoding) {
        set_ivar(context, "@_sax_encoding", name)?;
    }
    Ok(context)
}

fn context_bytes(context: Value) -> Result<Vec<u8>, Error> {
    let kind = ivar_string(context, "@_sax_kind").unwrap_or_default();
    if kind == "file" {
        let path = ivar_string(context, "@_sax_path").unwrap_or_default();
        return std::fs::read(&path).map_err(|error| Error::new(Ruby::get().unwrap().exception_runtime_error(), error.to_string()));
    }
    let input = get_ivar(context, "@input")?;
    if kind == "io" {
        return read_io(input);
    }
    bytes_of(input)
}

fn read_io(io: Value) -> Result<Vec<u8>, Error> {
    let mut all = Vec::new();
    loop {
        let chunk: Value = io.funcall("read", (8192,))?;
        if chunk.is_nil() {
            break;
        }
        let bytes = bytes_of(chunk)?;
        if bytes.is_empty() {
            break;
        }
        all.extend(bytes);
    }
    Ok(all)
}

fn install_push(ruby: &Ruby, this: Value, html: bool, encoding: Option<String>) -> Result<(), Error> {
    let state = ruby.obj_wrap(ParserState {
        inner: RefCell::new(PushInner {
            bytes: Vec::new(),
            events: Vec::new(),
            last_error: None,
            html,
            encoding,
        }),
    });
    set_ivar(this, "@_sax_state", state.as_value())?;
    set_ivar(this, "@_sax_options", 0)?;
    Ok(())
}

fn ensure_push(ruby: &Ruby, this: Value, html: bool) -> Result<Value, Error> {
    let value = get_ivar(this, "@_sax_state")?;
    if value.is_nil() {
        install_push(ruby, this, html, None)?;
        return get_ivar(this, "@_sax_state");
    }
    Ok(value)
}

fn expect_parser(ruby: &Ruby, parser: Value) -> Result<(), Error> {
    let class = sax_parser_class(ruby)?;
    if parser.is_kind_of(class) {
        return Ok(());
    }
    Err(Error::new(ruby.exception_arg_error(), "argument must be a Nokogiri::XML::SAX::Parser"))
}

fn sax_parser_class(ruby: &Ruby) -> Result<RClass, Error> {
    let nokogiri: RModule = ruby.class_object().const_get("Nokogiri")?;
    let xml: RModule = nokogiri.const_get("XML")?;
    let sax: RModule = xml.const_get("SAX")?;
    sax.const_get("Parser")
}

fn attribute_class(ruby: &Ruby) -> Result<RClass, Error> {
    let parser = sax_parser_class(ruby)?;
    parser.const_get("Attribute")
}

fn syntax_error(ruby: &Ruby, message: &str) -> Result<Error, Error> {
    let nokogiri: RModule = ruby.class_object().const_get("Nokogiri")?;
    let xml: RModule = nokogiri.const_get("XML")?;
    let class: RClass = xml.const_get("SyntaxError")?;
    let object = class.new_instance((message,))?;
    let exception: Exception = TryConvert::try_convert(object)?;
    Ok(exception.into())
}

fn call<T>(object: Value, method: &str, args: T) -> Result<(), Error>
where
    T: ArgList,
{
    object.funcall::<_, T, Value>(method, args)?;
    Ok(())
}

fn encoding_label(value: Value) -> Option<String> {
    if value.is_nil() {
        return None;
    }
    if let Ok(text) = <String as TryConvert>::try_convert(value) {
        return Some(text);
    }
    value.funcall("name", ()).ok()
}

fn check_encoding(ruby: &Ruby, value: Value) -> Result<(), Error> {
    if value.is_nil() {
        return Ok(());
    }
    let class: RClass = ruby.class_object().const_get("Encoding")?;
    if value.is_kind_of(class) {
        return Ok(());
    }
    Err(Error::new(ruby.exception_type_error(), "argument must be an Encoding object"))
}

fn expect_string(ruby: &Ruby, value: Value) -> Result<(), Error> {
    if value.is_kind_of(ruby.class_string()) {
        return Ok(());
    }
    let name = class_name(&value.class());
    Err(Error::new(ruby.exception_type_error(), format!("wrong argument type {name} (expected String)")))
}

fn class_name(class: &RClass) -> String {
    let name = unsafe { class.name() }.into_owned();
    match name.as_str() {
        "NilClass" => "nil".to_string(),
        "TrueClass" => "true".to_string(),
        "FalseClass" => "false".to_string(),
        _ => name,
    }
}

fn sax_failure_messages(error: &xmloxide::error::ParseError) -> Vec<String> {
    let mut messages = Vec::new();
    for diagnostic in &error.diagnostics {
        if diagnostic.severity != ErrorSeverity::Warning {
            messages.push(suite_message(&diagnostic.message));
        }
    }
    let primary = suite_message(&error.message);
    if messages.last().is_none_or(|item| item != &primary) {
        messages.push(primary);
    }
    messages
}

fn recover_messages(text: &str) -> Option<Vec<String>> {
    let options = ParseOptions::default().recover(true);
    let messages = match parse_str_with_options(text, &options) {
        Ok(doc) => doc
            .diagnostics
            .iter()
            .filter(|diagnostic| diagnostic.severity != ErrorSeverity::Warning)
            .map(|diagnostic| suite_message(&diagnostic.message))
            .collect(),
        Err(error) => sax_failure_messages(&error),
    };
    if messages.is_empty() { None } else { Some(messages) }
}

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

fn is_push(value: Value) -> bool {
    class_name(&value.class()).contains("PushParser")
}

fn truthy(value: Value) -> bool {
    if value.is_nil() {
        return false;
    }
    <bool as TryConvert>::try_convert(value).unwrap_or(true)
}

fn arg(ruby: &Ruby, args: &[Value], index: usize) -> Result<Value, Error> {
    args.get(index).copied().ok_or_else(|| Error::new(ruby.exception_arg_error(), "wrong number of arguments"))
}

fn bytes_of(value: Value) -> Result<Vec<u8>, Error> {
    if value.is_nil() {
        return Ok(Vec::new());
    }
    let text: magnus::RString = TryConvert::try_convert(value)?;
    Ok(unsafe { text.as_slice() }.to_vec())
}

fn set_ivar<T: IntoValue>(object: Value, name: &str, value: T) -> Result<(), Error> {
    object.funcall::<_, _, Value>("instance_variable_set", (name, value))?;
    Ok(())
}

fn get_ivar(object: Value, name: &str) -> Result<Value, Error> {
    object.funcall("instance_variable_get", (name,))
}

fn ivar_bool(object: Value, name: &str) -> Option<bool> {
    let value = get_ivar(object, name).ok()?;
    if value.is_nil() {
        return None;
    }
    <bool as TryConvert>::try_convert(value).ok()
}

fn ivar_i32(object: Value, name: &str) -> Option<i32> {
    let value = get_ivar(object, name).ok()?;
    if value.is_nil() {
        return None;
    }
    <i32 as TryConvert>::try_convert(value).ok()
}

fn ivar_string(object: Value, name: &str) -> Option<String> {
    let value = get_ivar(object, name).ok()?;
    if value.is_nil() {
        return None;
    }
    <String as TryConvert>::try_convert(value).ok()
}

fn opt(ruby: &Ruby, value: &Option<String>) -> Value {
    match value {
        Some(text) => ruby.str_new(text).as_value(),
        None => ruby.qnil().as_value(),
    }
}
