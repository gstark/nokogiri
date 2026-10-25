//! In-memory document tree shared by every Ruby node wrapper.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use magnus::Value;

pub const ELEMENT: i32 = 1;
pub const ATTRIBUTE: i32 = 2;
pub const TEXT: i32 = 3;
pub const CDATA: i32 = 4;
pub const ENTITY_REF: i32 = 5;
pub const ENTITY_NODE: i32 = 6;
pub const PI: i32 = 7;
pub const COMMENT: i32 = 8;
pub const DOCUMENT: i32 = 9;
pub const DOCUMENT_TYPE: i32 = 10;
pub const DOCUMENT_FRAG: i32 = 11;
pub const NOTATION: i32 = 12;
pub const HTML_DOCUMENT: i32 = 13;
pub const DTD: i32 = 14;
pub const ELEMENT_DECL: i32 = 15;
pub const ATTRIBUTE_DECL: i32 = 16;
pub const ENTITY_DECL: i32 = 17;

pub const XML_NS: &str = "http://www.w3.org/XML/1998/namespace";

#[derive(Clone, Debug)]
pub struct NodeData {
    pub kind: i32,
    pub name: Option<String>,
    pub content: String,
    pub parent: Option<u32>,
    pub children: Vec<u32>,
    pub attrs: Vec<u32>,
    pub ns: Option<u32>,
    pub ns_defs: Vec<u32>,
    pub owner: u32,
    pub line: i64,
    pub column: i64,
    pub version: String,
    pub encoding: Option<String>,
    pub url: Option<String>,
    pub lang: Option<String>,
    pub external_id: Option<String>,
    pub system_id: Option<String>,
    pub entity_type: i64,
    pub internal_subset: Option<u32>,
    pub external_subset: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct NsData {
    pub prefix: Option<String>,
    pub href: String,
}

/// Extra fields for DTD declarations. Ordinary nodes leave this empty.
#[derive(Clone, Debug)]
pub struct DeclData {
    pub prefix: Option<String>,
    pub element_type: i32,
    pub attr_type: String,
    pub attr_default: Option<String>,
    pub attr_default_kind: Option<String>,
    pub attr_enum: Vec<String>,
    pub elem_name: Option<String>,
    pub content_id: Option<u32>,
}

/// One node in an element declaration content model.
#[derive(Clone, Debug)]
pub struct ContentNode {
    pub name: Option<String>,
    pub prefix: Option<String>,
    pub kind: i32,
    pub occur: i32,
    pub c1: Option<u32>,
    pub c2: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct Notation {
    pub dtd: u32,
    pub name: String,
    pub public_id: Option<String>,
    pub system_id: Option<String>,
}

pub struct Store {
    pub nodes: Vec<NodeData>,
    pub nss: Vec<NsData>,
    pub wrappers: Vec<Option<Value>>,
    pub ns_wrappers: Vec<Option<Value>>,
    pub decls: HashMap<u32, DeclData>,
    pub contents: Vec<ContentNode>,
    pub notations: Vec<Notation>,
    pub key: u64,
    pub html: bool,
}

impl NodeData {
    fn blank(kind: i32, owner: u32) -> Self {
        Self {
            kind,
            name: None,
            content: String::new(),
            parent: None,
            children: Vec::new(),
            attrs: Vec::new(),
            ns: None,
            ns_defs: Vec::new(),
            owner,
            line: 0,
            column: 0,
            version: "1.0".to_string(),
            encoding: None,
            url: None,
            lang: None,
            external_id: None,
            system_id: None,
            entity_type: 1,
            internal_subset: None,
            external_subset: None,
        }
    }
}

impl Store {
    pub fn new_document(html: bool, key: u64) -> Rc<RefCell<Self>> {
        let kind = if html { HTML_DOCUMENT } else { DOCUMENT };
        let mut doc = NodeData::blank(kind, 0);
        doc.name = Some("document".to_string());
        doc.owner = 0;
        let store = Self {
            nodes: vec![doc],
            nss: vec![NsData { prefix: Some("xml".to_string()), href: XML_NS.to_string() }],
            wrappers: vec![None],
            ns_wrappers: vec![None],
            decls: HashMap::new(),
            contents: Vec::new(),
            notations: Vec::new(),
            key,
            html,
        };
        Rc::new(RefCell::new(store))
    }

    pub fn alloc(&mut self, kind: i32, owner: u32) -> u32 {
        let id = self.nodes.len() as u32;
        let mut node = NodeData::blank(kind, owner);
        node.owner = owner;
        self.nodes.push(node);
        self.wrappers.push(None);
        id
    }

    pub fn add_ns(&mut self, prefix: Option<String>, href: String) -> u32 {
        let id = self.nss.len() as u32;
        self.nss.push(NsData { prefix, href });
        self.ns_wrappers.push(None);
        id
    }

    pub fn unlink(&mut self, id: u32) {
        let Some(parent) = self.nodes[id as usize].parent else {
            return;
        };
        self.nodes[parent as usize].children.retain(|child| *child != id);
        self.nodes[parent as usize].attrs.retain(|child| *child != id);
        self.nodes[id as usize].parent = None;
    }

    pub fn append_child(&mut self, parent: u32, child: u32) {
        if parent == child {
            return;
        }
        self.unlink(child);
        self.nodes[child as usize].parent = Some(parent);
        self.nodes[child as usize].owner = self.nodes[parent as usize].owner;
        let kind = self.nodes[child as usize].kind;
        if kind == ATTRIBUTE {
            self.nodes[parent as usize].attrs.push(child);
        } else {
            self.nodes[parent as usize].children.push(child);
        }
    }

    pub fn insert_before(&mut self, sibling: u32, node: u32) {
        let Some(parent) = self.nodes[sibling as usize].parent else {
            return;
        };
        self.unlink(node);
        self.nodes[node as usize].parent = Some(parent);
        self.nodes[node as usize].owner = self.nodes[parent as usize].owner;
        let children = &mut self.nodes[parent as usize].children;
        let index = children.iter().position(|id| *id == sibling).unwrap_or(children.len());
        children.insert(index, node);
    }

    pub fn insert_after(&mut self, sibling: u32, node: u32) {
        let Some(parent) = self.nodes[sibling as usize].parent else {
            return;
        };
        self.unlink(node);
        self.nodes[node as usize].parent = Some(parent);
        self.nodes[node as usize].owner = self.nodes[parent as usize].owner;
        let children = &mut self.nodes[parent as usize].children;
        let index = children
            .iter()
            .position(|id| *id == sibling)
            .map(|index| index + 1)
            .unwrap_or(children.len());
        children.insert(index, node);
    }

    pub fn replace_with(&mut self, old: u32, new_node: u32) {
        let Some(parent) = self.nodes[old as usize].parent else {
            return;
        };
        self.unlink(new_node);
        let children = &mut self.nodes[parent as usize].children;
        if let Some(index) = children.iter().position(|id| *id == old) {
            children[index] = new_node;
            self.nodes[new_node as usize].parent = Some(parent);
            self.nodes[new_node as usize].owner = self.nodes[parent as usize].owner;
            self.nodes[old as usize].parent = None;
        }
    }

    pub fn root_element(&self, doc: u32) -> Option<u32> {
        self.nodes[doc as usize]
            .children
            .iter()
            .copied()
            .find(|id| self.nodes[*id as usize].kind == ELEMENT)
    }

    pub fn node_name(&self, id: u32) -> Option<String> {
        match self.nodes[id as usize].kind {
            CDATA => None,
            DOCUMENT_FRAG => Some("#document-fragment".to_string()),
            _ => self.nodes[id as usize].name.clone(),
        }
    }

    pub fn local_name(&self, id: u32) -> String {
        self.node_name(id).unwrap_or_default()
    }

    pub fn qualified_name(&self, id: u32) -> String {
        let local = self.local_name(id);
        if self.nodes[id as usize].kind != ELEMENT && self.nodes[id as usize].kind != ATTRIBUTE {
            return local;
        }
        match self.nodes[id as usize].ns.and_then(|ns| self.nss[ns as usize].prefix.clone()) {
            Some(prefix) if !prefix.is_empty() => format!("{prefix}:{local}"),
            _ => local,
        }
    }

    pub fn text_content(&self, id: u32) -> String {
        match self.nodes[id as usize].kind {
            TEXT | CDATA | COMMENT | PI | ATTRIBUTE | ENTITY_REF | ENTITY_DECL => {
                self.nodes[id as usize].content.clone()
            }
            _ => {
                let mut out = String::new();
                self.collect_text(id, &mut out);
                out
            }
        }
    }

    fn collect_text(&self, id: u32, out: &mut String) {
        for child in &self.nodes[id as usize].children {
            match self.nodes[*child as usize].kind {
                TEXT | CDATA | ENTITY_REF => out.push_str(&self.nodes[*child as usize].content),
                ELEMENT | DOCUMENT | HTML_DOCUMENT | DOCUMENT_FRAG => self.collect_text(*child, out),
                _ => {}
            }
        }
    }

    pub fn is_blank_text(&self, id: u32) -> bool {
        matches!(self.nodes[id as usize].kind, TEXT | CDATA)
            && self.nodes[id as usize].content.chars().all(char::is_whitespace)
    }

    pub fn pointer_id(&self, id: u32) -> u64 {
        (self.key << 32) | u64::from(id)
    }

    pub fn compare(&self, left: u32, right: u32) -> i32 {
        if left == right {
            return 0;
        }
        if self.ancestor_of(left, right) {
            return -1;
        }
        if self.ancestor_of(right, left) {
            return 1;
        }
        let left_chain = self.chain(left);
        let right_chain = self.chain(right);
        let mut index = 0;
        while index < left_chain.len() && index < right_chain.len() && left_chain[index] == right_chain[index] {
            index += 1;
        }
        if index == 0 || index >= left_chain.len() || index >= right_chain.len() {
            return if left < right { -1 } else { 1 };
        }
        let parent = left_chain[index - 1];
        let left_pos = self.child_index(parent, left_chain[index]);
        let right_pos = self.child_index(parent, right_chain[index]);
        if left_pos <= right_pos { -1 } else { 1 }
    }

    fn child_index(&self, parent: u32, child: u32) -> usize {
        let node = &self.nodes[parent as usize];
        if let Some(index) = node.attrs.iter().position(|id| *id == child) {
            return index;
        }
        if let Some(index) = node.children.iter().position(|id| *id == child) {
            return node.attrs.len() + index;
        }
        usize::MAX
    }

    fn chain(&self, mut id: u32) -> Vec<u32> {
        let mut chain = vec![id];
        while let Some(parent) = self.nodes[id as usize].parent {
            chain.push(parent);
            id = parent;
        }
        chain.reverse();
        chain
    }

    fn ancestor_of(&self, ancestor: u32, mut node: u32) -> bool {
        while let Some(parent) = self.nodes[node as usize].parent {
            if parent == ancestor {
                return true;
            }
            node = parent;
        }
        false
    }

    pub fn lookup_ns(&self, mut node: u32, prefix: Option<&str>) -> Option<u32> {
        if prefix == Some("xml") {
            return self.find_xml_ns();
        }
        loop {
            for def in &self.nodes[node as usize].ns_defs {
                let ns = &self.nss[*def as usize];
                let matches = match prefix {
                    None => ns.prefix.is_none(),
                    Some(wanted) => ns.prefix.as_deref() == Some(wanted),
                };
                if matches {
                    return Some(*def);
                }
            }
            match self.nodes[node as usize].parent {
                Some(parent) => node = parent,
                None => return None,
            }
        }
    }

    pub fn find_xml_ns(&self) -> Option<u32> {
        self.nss.iter().position(|ns| ns.prefix.as_deref() == Some("xml") && ns.href == XML_NS).map(|index| index as u32)
    }

    pub fn ensure_xml_ns(&mut self) -> u32 {
        if let Some(index) = self.find_xml_ns() {
            return index;
        }
        self.add_ns(Some("xml".to_string()), XML_NS.to_string())
    }

    pub fn namespace_scopes(&self, id: u32) -> Vec<u32> {
        let mut scopes = Vec::new();
        let mut seen_default = false;
        let mut seen_prefix: Vec<String> = Vec::new();
        let mut node = Some(id);
        while let Some(current) = node {
            for def in self.nodes[current as usize].ns_defs.iter().rev() {
                let ns = &self.nss[*def as usize];
                if ns.prefix.as_deref() == Some("xml") {
                    continue;
                }
                if let Some(prefix) = &ns.prefix {
                    if seen_prefix.iter().any(|seen| seen == prefix) {
                        continue;
                    }
                    seen_prefix.push(prefix.clone());
                    scopes.push(*def);
                } else if !seen_default {
                    seen_default = true;
                    scopes.push(*def);
                }
            }
            node = self.nodes[current as usize].parent;
        }
        scopes.reverse();
        scopes
    }

    pub fn remove_namespaces(&mut self) {
        for node in &mut self.nodes {
            node.ns = None;
            node.ns_defs.clear();
        }
    }

    /// Walk ancestors, including `node`, for an in-scope namespace declaration with `href`.
    /// A closer declaration with the same prefix hides an outer declaration.
    pub fn lookup_ns_by_href(&self, mut node: u32, href: &str) -> Option<u32> {
        let mut hidden: Vec<Option<String>> = Vec::new();
        loop {
            let kind = self.nodes[node as usize].kind;
            if kind == ELEMENT || kind == DOCUMENT || kind == HTML_DOCUMENT {
                let defs = self.nodes[node as usize].ns_defs.clone();
                for def in &defs {
                    let prefix = self.nss[*def as usize].prefix.clone();
                    if hidden.iter().any(|seen| seen == &prefix) {
                        continue;
                    }
                    if self.nss[*def as usize].href == href {
                        return Some(*def);
                    }
                }
                for def in &defs {
                    let prefix = self.nss[*def as usize].prefix.clone();
                    if !hidden.iter().any(|seen| seen == &prefix) {
                        hidden.push(prefix);
                    }
                }
            }
            match self.nodes[node as usize].parent {
                Some(parent) => node = parent,
                None => return None,
            }
        }
    }

    /// Match libxml reparenting: bind prefixes, inherit the parent namespace, and drop
    /// declarations that are already in scope on the parent.
    pub fn relink_namespace(&mut self, id: u32, inheritance: bool) {
        let kind = self.nodes[id as usize].kind;
        if kind != ELEMENT && kind != ATTRIBUTE {
            return;
        }
        let prefix_missing = match self.nodes[id as usize].ns {
            None => true,
            Some(ns) => self.nss[ns as usize].prefix.is_none(),
        };
        if prefix_missing {
            let name = self.nodes[id as usize].name.clone().unwrap_or_default();
            if let Some((prefix, local)) = split_qname_owned(&name) {
                if kind == ATTRIBUTE && prefix == "xmlns" {
                    return;
                }
                if let Some(ns) = self.lookup_ns(id, Some(&prefix)) {
                    self.nodes[id as usize].name = Some(local);
                    self.nodes[id as usize].ns = Some(ns);
                }
            } else if kind == ATTRIBUTE {
                return;
            } else if let Some(ns) = self.lookup_ns(id, None) {
                self.nodes[id as usize].ns = Some(ns);
            }
        }
        if kind != ELEMENT {
            return;
        }
        let Some(parent) = self.nodes[id as usize].parent else {
            return;
        };
        let parent_kind = self.nodes[parent as usize].kind;
        let parent_is_document = parent_kind == DOCUMENT || parent_kind == HTML_DOCUMENT;
        if self.nodes[id as usize].ns.is_none() && !parent_is_document && inheritance {
            let parent_ns = self.nodes[parent as usize].ns;
            self.nodes[id as usize].ns = parent_ns;
        }
        let defs = self.nodes[id as usize].ns_defs.clone();
        let mut kept = Vec::with_capacity(defs.len());
        for def in defs {
            let prefix = self.nss[def as usize].prefix.clone();
            let href = self.nss[def as usize].href.clone();
            let redundant = self.lookup_ns_by_href(parent, &href).is_some_and(|ns| {
                ns != def && self.nss[ns as usize].prefix == prefix
            });
            if !redundant {
                kept.push(def);
            }
        }
        self.nodes[id as usize].ns_defs = kept;
        if let Some(current) = self.nodes[id as usize].ns {
            let prefix = self.nss[current as usize].prefix.clone();
            let href = self.nss[current as usize].href.clone();
            if let Some(ns) = self.lookup_ns(id, prefix.as_deref()) {
                if ns != current
                    && self.nss[ns as usize].prefix == prefix
                    && self.nss[ns as usize].href == href
                {
                    self.nodes[id as usize].ns = Some(ns);
                }
            }
        }
        if self.nodes[id as usize].ns.is_none() {
            return;
        }
        let children = self.nodes[id as usize].children.clone();
        let attrs = self.nodes[id as usize].attrs.clone();
        for child in children {
            self.relink_namespace(child, inheritance);
        }
        for attr in attrs {
            self.relink_namespace(attr, inheritance);
        }
    }

    pub fn set_owner_deep(&mut self, id: u32, owner: u32) {
        self.nodes[id as usize].owner = owner;
        let children = self.nodes[id as usize].children.clone();
        let attrs = self.nodes[id as usize].attrs.clone();
        for child in children.into_iter().chain(attrs) {
            self.set_owner_deep(child, owner);
        }
    }
}

fn split_qname_owned(name: &str) -> Option<(String, String)> {
    let (prefix, local) = name.split_once(':')?;
    if prefix.is_empty() || local.is_empty() {
        return None;
    }
    Some((prefix.to_string(), local.to_string()))
}

/// Copy `id` and its subtree into `dest`. Returns the new id.
pub fn copy_subtree(src: &Store, dest: &mut Store, id: u32, owner: u32, deep: bool) -> u32 {
    let kind = src.nodes[id as usize].kind;
    let new_id = dest.alloc(kind, owner);
    let from = &src.nodes[id as usize];
    let ns = from.ns.and_then(|ns_id| {
        let ns = &src.nss[ns_id as usize];
        Some(dest.add_ns(ns.prefix.clone(), ns.href.clone()))
    });
    let mut ns_defs = Vec::new();
    for def in &from.ns_defs {
        let ns = &src.nss[*def as usize];
        ns_defs.push(dest.add_ns(ns.prefix.clone(), ns.href.clone()));
    }
    {
        let node = &mut dest.nodes[new_id as usize];
        node.name = from.name.clone();
        node.content = from.content.clone();
        node.ns = ns;
        node.ns_defs = ns_defs;
        node.line = from.line;
        node.column = from.column;
        node.version = from.version.clone();
        node.encoding = from.encoding.clone();
        node.url = from.url.clone();
        node.lang = from.lang.clone();
        node.external_id = from.external_id.clone();
        node.system_id = from.system_id.clone();
        node.entity_type = from.entity_type;
        node.owner = owner;
    }
    copy_decl(src, dest, id, new_id, false);
    if !deep {
        return new_id;
    }
    let children = src.nodes[id as usize].children.clone();
    let attrs = src.nodes[id as usize].attrs.clone();
    let subset = src.nodes[id as usize].internal_subset;
    let external = src.nodes[id as usize].external_subset;
    for child in children {
        let copied = copy_subtree(src, dest, child, owner, true);
        dest.append_child(new_id, copied);
        if Some(child) == subset {
            dest.nodes[new_id as usize].internal_subset = Some(copied);
        }
        if Some(child) == external {
            dest.nodes[new_id as usize].external_subset = Some(copied);
        }
    }
    for attr in attrs {
        let copied = copy_subtree(src, dest, attr, owner, true);
        dest.append_child(new_id, copied);
    }
    new_id
}

/// Copy `id` inside one store. Namespace ids stay shared with the source.
pub fn copy_within(store: &mut Store, id: u32, owner: u32, deep: bool) -> u32 {
    let from = store.nodes[id as usize].clone();
    let new_id = store.alloc(from.kind, owner);
    {
        let node = &mut store.nodes[new_id as usize];
        node.name = from.name.clone();
        node.content = from.content.clone();
        node.ns = from.ns;
        node.ns_defs = from.ns_defs.clone();
        node.line = from.line;
        node.column = from.column;
        node.version = from.version.clone();
        node.encoding = from.encoding.clone();
        node.url = from.url.clone();
        node.lang = from.lang.clone();
        node.external_id = from.external_id.clone();
        node.system_id = from.system_id.clone();
        node.entity_type = from.entity_type;
        node.owner = owner;
        node.parent = None;
        node.children.clear();
        node.attrs.clear();
        node.internal_subset = None;
        node.external_subset = None;
    }
    if let Some(extra) = store.decls.get(&id).cloned() {
        store.decls.insert(new_id, extra);
    }
    if from.kind == DTD {
        let notes: Vec<Notation> = store.notations.iter().filter(|note| note.dtd == id).cloned().collect();
        for mut note in notes {
            note.dtd = new_id;
            store.notations.push(note);
        }
    }
    if !deep {
        return new_id;
    }
    for child in &from.children {
        let copied = copy_within(store, *child, owner, true);
        store.append_child(new_id, copied);
        if Some(*child) == from.internal_subset {
            store.nodes[new_id as usize].internal_subset = Some(copied);
        }
        if Some(*child) == from.external_subset {
            store.nodes[new_id as usize].external_subset = Some(copied);
        }
    }
    for attr in &from.attrs {
        let copied = copy_within(store, *attr, owner, true);
        store.append_child(new_id, copied);
    }
    new_id
}

fn copy_decl(src: &Store, dest: &mut Store, old_id: u32, new_id: u32, _share: bool) {
    if let Some(mut extra) = src.decls.get(&old_id).cloned() {
        if let Some(content) = extra.content_id {
            extra.content_id = Some(copy_content_tree(src, dest, content));
        }
        dest.decls.insert(new_id, extra);
    }
    if src.nodes[old_id as usize].kind == DTD {
        let notes: Vec<Notation> = src.notations.iter().filter(|note| note.dtd == old_id).cloned().collect();
        for mut note in notes {
            note.dtd = new_id;
            dest.notations.push(note);
        }
    }
}

fn copy_content_tree(src: &Store, dest: &mut Store, id: u32) -> u32 {
    let from = src.contents[id as usize].clone();
    let c1 = from.c1.map(|child| copy_content_tree(src, dest, child));
    let c2 = from.c2.map(|child| copy_content_tree(src, dest, child));
    let new_id = dest.contents.len() as u32;
    dest.contents.push(ContentNode {
        name: from.name,
        prefix: from.prefix,
        kind: from.kind,
        occur: from.occur,
        c1,
        c2,
    });
    new_id
}
