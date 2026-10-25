//! XPath 1.0 evaluator for the in-memory document store.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::store::{Store, ATTRIBUTE, COMMENT, ELEMENT, PI, TEXT, CDATA};

/// Called for a function the built-in table does not implement.
/// `Ok(None)` means the function is not a custom handler function.
pub type XPathFunction<'a> = dyn FnMut(&str, &[XValue]) -> Result<Option<XValue>, String> + 'a;

#[derive(Clone, Debug)]
pub enum XValue {
    Nodes(Vec<u32>),
    Nss(Vec<u32>),
    Bool(bool),
    Num(f64),
    Str(String),
}

#[derive(Clone, Debug)]
enum Expr {
    Or(Box<Expr>, Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Eq(Box<Expr>, Box<Expr>, bool),
    Rel(Box<Expr>, Box<Expr>, RelOp),
    Add(Box<Expr>, Box<Expr>, bool),
    Mul(Box<Expr>, Box<Expr>, MulOp),
    Neg(Box<Expr>),
    Union(Vec<Expr>),
    Path(bool, Vec<Step>),
    From(Box<Expr>, Vec<Step>),
    Filter(Box<Expr>, Vec<Expr>),
    Literal(String),
    Number(f64),
    Var(String),
    Call(String, Vec<Expr>),
}

#[derive(Clone, Copy, Debug)]
enum RelOp { Lt, Le, Gt, Ge }

#[derive(Clone, Copy, Debug)]
enum MulOp { Mul, Div, Mod }

#[derive(Clone, Debug)]
struct Step {
    axis: Axis,
    test: NodeTest,
    preds: Vec<Expr>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Axis {
    Child,
    Descendant,
    DescendantOrSelf,
    Parent,
    Ancestor,
    AncestorOrSelf,
    FollowingSibling,
    PrecedingSibling,
    Following,
    Preceding,
    Self_,
    Attribute,
    Namespace,
}

#[derive(Clone, Debug)]
enum NodeTest {
    Name { prefix: Option<String>, local: Option<String> },
    Node,
    Text,
    Comment,
    Pi(Option<String>),
}

struct Parser<'a> {
    s: &'a str,
    i: usize,
}

impl<'a> Parser<'a> {
    fn new(s: &'a str) -> Self {
        Self { s, i: 0 }
    }

    fn rest(&self) -> &'a str {
        &self.s[self.i..]
    }

    fn skip(&mut self) {
        self.i += self.rest().chars().take_while(|c| c.is_whitespace()).map(|c| c.len_utf8()).sum::<usize>();
    }

    fn starts(&mut self, token: &str) -> bool {
        self.skip();
        self.rest().starts_with(token)
    }

    fn eat(&mut self, token: &str) -> bool {
        self.skip();
        if self.rest().starts_with(token) {
            let next = self.rest()[token.len()..].chars().next();
            let boundary = token.chars().all(|c| c.is_ascii_alphabetic());
            if boundary && next.is_some_and(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
                return false;
            }
            self.i += token.len();
            true
        } else {
            false
        }
    }

    fn parse(&mut self) -> Result<Expr, String> {
        let expr = self.parse_or()?;
        self.skip();
        if self.i < self.s.len() {
            return Err(format!("Invalid expression: {}", self.rest()));
        }
        Ok(expr)
    }

    fn parse_or(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_and()?;
        while self.eat("or") {
            left = Expr::Or(Box::new(left), Box::new(self.parse_and()?));
        }
        Ok(left)
    }

    fn parse_and(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_eq()?;
        while self.eat("and") {
            left = Expr::And(Box::new(left), Box::new(self.parse_eq()?));
        }
        Ok(left)
    }

    fn parse_eq(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_rel()?;
        loop {
            if self.eat("!=") {
                left = Expr::Eq(Box::new(left), Box::new(self.parse_rel()?), true);
            } else if self.eat("=") {
                left = Expr::Eq(Box::new(left), Box::new(self.parse_rel()?), false);
            } else {
                break;
            }
        }
        Ok(left)
    }

    fn parse_rel(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_add()?;
        loop {
            let op = if self.eat("<=") {
                RelOp::Le
            } else if self.eat(">=") {
                RelOp::Ge
            } else if self.eat("<") {
                RelOp::Lt
            } else if self.eat(">") {
                RelOp::Gt
            } else {
                break;
            };
            left = Expr::Rel(Box::new(left), Box::new(self.parse_add()?), op);
        }
        Ok(left)
    }

    fn parse_add(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_mul()?;
        loop {
            let minus = if self.eat("+") {
                false
            } else if self.eat("-") {
                true
            } else {
                break;
            };
            left = Expr::Add(Box::new(left), Box::new(self.parse_mul()?), minus);
        }
        Ok(left)
    }

    fn parse_mul(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_unary()?;
        loop {
            let op = if self.eat("*") {
                MulOp::Mul
            } else if self.eat("div") {
                MulOp::Div
            } else if self.eat("mod") {
                MulOp::Mod
            } else {
                break;
            };
            left = Expr::Mul(Box::new(left), Box::new(self.parse_unary()?), op);
        }
        Ok(left)
    }

    fn parse_unary(&mut self) -> Result<Expr, String> {
        if self.eat("-") {
            return Ok(Expr::Neg(Box::new(self.parse_unary()?)));
        }
        self.parse_union()
    }

    fn parse_union(&mut self) -> Result<Expr, String> {
        let mut items = vec![self.parse_path()?];
        while self.eat("|") {
            items.push(self.parse_path()?);
        }
        if items.len() == 1 {
            Ok(items.pop().unwrap())
        } else {
            Ok(Expr::Union(items))
        }
    }

    fn parse_path(&mut self) -> Result<Expr, String> {
        self.skip();
        if self.rest().starts_with('/') {
            let mut steps = Vec::new();
            self.i += 1;
            if self.rest().starts_with('/') {
                self.i += 1;
                steps.push(Step { axis: Axis::DescendantOrSelf, test: NodeTest::Node, preds: Vec::new() });
            }
            if self.path_continues() {
                steps.extend(self.parse_rel_steps()?);
            }
            return Ok(Expr::Path(true, steps));
        }
        if self.looks_like_step() {
            let steps = self.parse_rel_steps()?;
            return Ok(Expr::Path(false, steps));
        }
        let mut expr = self.parse_primary()?;
        let mut preds = Vec::new();
        while self.starts("[") {
            self.eat("[");
            preds.push(self.parse_or()?);
            if !self.eat("]") {
                return Err("Missing ]".to_string());
            }
        }
        if !preds.is_empty() {
            expr = Expr::Path(false, vec![Step { axis: Axis::Self_, test: NodeTest::Node, preds }]).filtered(expr);
        }
        if self.starts("/") {
            let more = self.parse_tail_steps()?;
            return Ok(Expr::From(Box::new(expr), more));
        }
        Ok(expr)
    }

    fn path_continues(&mut self) -> bool {
        self.skip();
        let rest = self.rest();
        if rest.is_empty() || rest.starts_with(|c: char| ")]|".contains(c)) {
            return false;
        }
        !rest.starts_with("or") && !rest.starts_with("and") && !rest.starts_with('=') && !rest.starts_with('!')
            && !rest.starts_with('<') && !rest.starts_with('>') && !rest.starts_with('+')
    }

    fn looks_like_step(&mut self) -> bool {
        self.skip();
        let rest = self.rest();
        // A numeric predicate such as [1] is a number, not an element name.
        if rest.starts_with(|c: char| c.is_ascii_digit()) {
            return false;
        }
        if rest.starts_with('.') && !rest.starts_with("..") {
            if rest[1..].starts_with(|c: char| c.is_ascii_digit()) {
                return false;
            }
        }
        if rest.starts_with('.') || rest.starts_with('@') || rest.starts_with('*') || rest.starts_with(':') {
            return true;
        }
        let name_len = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
            .map(|c| c.len_utf8())
            .sum::<usize>();
        if name_len == 0 {
            return false;
        }
        let name = &rest[..name_len];
        let after = rest[name_len..].trim_start();
        if after.starts_with('(') {
            return matches!(name, "node" | "text" | "comment" | "processing-instruction");
        }
        // `prefix:local(` is a function call, not a step.
        if after.starts_with(':') && !after.starts_with("::") {
            let rest2 = &after[1..];
            let local_len = rest2
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-' || *c == '.')
                .map(|c| c.len_utf8())
                .sum::<usize>();
            if local_len > 0 && rest2[local_len..].trim_start().starts_with('(') {
                return false;
            }
        }
        true
    }

    fn parse_rel_steps(&mut self) -> Result<Vec<Step>, String> {
        let mut steps = vec![self.parse_step()?];
        while self.starts("/") {
            steps.extend(self.parse_tail_steps()?);
        }
        Ok(steps)
    }

    fn parse_tail_steps(&mut self) -> Result<Vec<Step>, String> {
        let mut steps = Vec::new();
        while self.starts("/") {
            self.eat("/");
            if self.starts("/") {
                self.eat("/");
                steps.push(Step { axis: Axis::DescendantOrSelf, test: NodeTest::Node, preds: Vec::new() });
            }
            steps.push(self.parse_step()?);
        }
        Ok(steps)
    }

    fn parse_step(&mut self) -> Result<Step, String> {
        self.skip();
        if self.eat("..") {
            return Ok(self.with_preds(Step { axis: Axis::Parent, test: NodeTest::Node, preds: Vec::new() })?);
        }
        if self.eat(".") {
            return Ok(self.with_preds(Step { axis: Axis::Self_, test: NodeTest::Node, preds: Vec::new() })?);
        }
        if self.eat("@") {
            let test = self.parse_node_test(true)?;
            return Ok(self.with_preds(Step { axis: Axis::Attribute, test, preds: Vec::new() })?);
        }
        if let Some(axis) = self.try_axis() {
            let test = self.parse_node_test(axis == Axis::Attribute)?;
            return Ok(self.with_preds(Step { axis, test, preds: Vec::new() })?);
        }
        let test = self.parse_node_test(false)?;
        Ok(self.with_preds(Step { axis: Axis::Child, test, preds: Vec::new() })?)
    }

    fn with_preds(&mut self, mut step: Step) -> Result<Step, String> {
        while self.starts("[") {
            self.eat("[");
            step.preds.push(self.parse_or()?);
            if !self.eat("]") {
                return Err("Missing ]".to_string());
            }
        }
        Ok(step)
    }

    fn try_axis(&mut self) -> Option<Axis> {
        self.skip();
        let rest = self.rest();
        let name_len = rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-').map(|c| c.len_utf8()).sum::<usize>();
        if name_len == 0 || !rest[name_len..].starts_with("::") {
            return None;
        }
        let name = &rest[..name_len];
        let axis = match name {
            "child" => Axis::Child,
            "descendant" => Axis::Descendant,
            "descendant-or-self" => Axis::DescendantOrSelf,
            "parent" => Axis::Parent,
            "ancestor" => Axis::Ancestor,
            "ancestor-or-self" => Axis::AncestorOrSelf,
            "following-sibling" => Axis::FollowingSibling,
            "preceding-sibling" => Axis::PrecedingSibling,
            "following" => Axis::Following,
            "preceding" => Axis::Preceding,
            "self" => Axis::Self_,
            "attribute" => Axis::Attribute,
            "namespace" => Axis::Namespace,
            _ => return None,
        };
        self.i += name_len + 2;
        Some(axis)
    }

    fn at_call(&mut self, name: &str) -> bool {
        self.skip();
        let rest = self.rest();
        rest.starts_with(name) && rest[name.len()..].trim_start().starts_with('(')
    }

    fn parse_node_test(&mut self, attr: bool) -> Result<NodeTest, String> {
        self.skip();
        if self.at_call("node") && self.eat("node") && self.eat("(") && self.eat(")") {
            return Ok(NodeTest::Node);
        }
        if self.at_call("text") && self.eat("text") && self.eat("(") && self.eat(")") {
            return Ok(NodeTest::Text);
        }
        if self.at_call("comment") && self.eat("comment") && self.eat("(") && self.eat(")") {
            return Ok(NodeTest::Comment);
        }
        if self.at_call("processing-instruction") && self.eat("processing-instruction") && self.eat("(") {
            self.skip();
            let target = if self.rest().starts_with('"') || self.rest().starts_with('\'') {
                Some(self.parse_string()?)
            } else {
                None
            };
            if !self.eat(")") {
                return Err("Missing )".to_string());
            }
            return Ok(NodeTest::Pi(target));
        }
        if self.eat("*") {
            return Ok(NodeTest::Name { prefix: None, local: None });
        }
        let (prefix, local) = self.parse_qname()?;
        if local.as_deref() == Some("*") {
            return Ok(NodeTest::Name { prefix, local: None });
        }
        let _ = attr;
        Ok(NodeTest::Name { prefix, local })
    }

    fn parse_qname(&mut self) -> Result<(Option<String>, Option<String>), String> {
        self.skip();
        if self.rest().starts_with(':') && !self.rest().starts_with("::") {
            self.i += 1;
            let local = self.parse_ncname()?;
            return Ok((Some(String::new()), Some(local)));
        }
        let first = self.parse_ncname()?;
        if self.rest().starts_with(':') && !self.rest().starts_with("::") {
            self.i += 1;
            if self.eat("*") {
                return Ok((Some(first), None));
            }
            let local = self.parse_ncname()?;
            return Ok((Some(first), Some(local)));
        }
        Ok((None, Some(first)))
    }

    fn parse_ncname(&mut self) -> Result<String, String> {
        self.skip();
        let rest = self.rest();
        let len = rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-' || *c == '.').map(|c| c.len_utf8()).sum::<usize>();
        if len == 0 {
            return Err("Expected name".to_string());
        }
        let name = rest[..len].to_string();
        self.i += len;
        Ok(name)
    }

    fn parse_primary(&mut self) -> Result<Expr, String> {
        self.skip();
        if self.rest().starts_with('"') || self.rest().starts_with('\'') {
            return Ok(Expr::Literal(self.parse_string()?));
        }
        if self.rest().starts_with(|c: char| c.is_ascii_digit() || c == '.') && !self.rest().starts_with("..") {
            if let Some(number) = self.try_number() {
                return Ok(Expr::Number(number));
            }
        }
        if self.eat("$") {
            let (prefix, local) = self.parse_qname()?;
            let name = match (prefix, local) {
                (Some(prefix), Some(local)) => format!("{prefix}:{local}"),
                (_, Some(local)) => local,
                _ => return Err("Expected variable name".to_string()),
            };
            return Ok(Expr::Var(name));
        }
        if self.eat("(") {
            let expr = self.parse_or()?;
            if !self.eat(")") {
                return Err("Missing )".to_string());
            }
            return Ok(expr);
        }
        let saved = self.i;
        if let Ok(mut name) = self.parse_ncname() {
            if self.rest().starts_with(':') && !self.rest().starts_with("::") {
                self.i += 1;
                if let Ok(local) = self.parse_ncname() {
                    if self.starts("(") {
                        name = format!("{name}:{local}");
                    } else {
                        self.i = saved;
                        return Err(format!("Invalid expression: {}", self.rest()));
                    }
                } else {
                    self.i = saved;
                }
            }
            if self.eat("(") {
                let mut args = Vec::new();
                self.skip();
                if !self.starts(")") {
                    loop {
                        args.push(self.parse_or()?);
                        if !self.eat(",") {
                            break;
                        }
                    }
                }
                if !self.eat(")") {
                    return Err("Missing )".to_string());
                }
                return Ok(Expr::Call(name, args));
            }
            self.i = saved;
        }
        Err(format!("Invalid expression: {}", self.rest()))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        self.skip();
        let quote = self.rest().chars().next().ok_or("Expected string")?;
        self.i += quote.len_utf8();
        let mut out = String::new();
        while let Some(ch) = self.rest().chars().next() {
            self.i += ch.len_utf8();
            if ch == quote {
                return Ok(out);
            }
            out.push(ch);
        }
        Err("Unterminated string".to_string())
    }

    fn try_number(&mut self) -> Option<f64> {
        self.skip();
        let rest = self.rest();
        let mut len = 0;
        let bytes = rest.as_bytes();
        while len < bytes.len() && bytes[len].is_ascii_digit() {
            len += 1;
        }
        if len < bytes.len() && bytes[len] == b'.' {
            len += 1;
            while len < bytes.len() && bytes[len].is_ascii_digit() {
                len += 1;
            }
        }
        if len == 0 || &rest[..len] == "." {
            return None;
        }
        let number = rest[..len].parse().ok()?;
        self.i += len;
        Some(number)
    }
}

trait Filtered {
    fn filtered(self, _primary: Expr) -> Expr;
}

impl Filtered for Expr {
    fn filtered(self, primary: Expr) -> Expr {
        match self {
            Expr::Path(_, steps) => Expr::Filter(Box::new(primary), steps.into_iter().flat_map(|step| step.preds).collect()),
            other => other,
        }
    }
}

pub fn evaluate<'a>(
    store: Rc<RefCell<Store>>,
    context: u32,
    expr: &str,
    namespaces: &'a HashMap<String, String>,
    variables: &'a HashMap<String, XValue>,
    functions: Option<&'a mut XPathFunction<'a>>,
) -> Result<XValue, String> {
    check_prefixes(expr, namespaces)?;
    let ast = Parser::new(expr).parse()?;
    let mut ctx = Eval { store, node: context, position: 1, size: 1, namespaces, variables, functions };
    let value = ctx.eval(&ast)?;
    let store = ctx.store.borrow();
    Ok(sort_result(&store, value))
}

struct Eval<'a> {
    store: Rc<RefCell<Store>>,
    node: u32,
    position: usize,
    size: usize,
    namespaces: &'a HashMap<String, String>,
    variables: &'a HashMap<String, XValue>,
    functions: Option<&'a mut XPathFunction<'a>>,
}

impl<'a> Eval<'a> {
    fn eval(&mut self, expr: &Expr) -> Result<XValue, String> {
        match expr {
            Expr::Or(left, right) => Ok(XValue::Bool(self.bool(left)? || self.bool(right)?)),
            Expr::And(left, right) => Ok(XValue::Bool(self.bool(left)? && self.bool(right)?)),
            Expr::Eq(left, right, not) => {
                let equal = self.equal(left, right)?;
                Ok(XValue::Bool(if *not { !equal } else { equal }))
            }
            Expr::Rel(left, right, op) => {
                let l = self.number(left)?;
                let r = self.number(right)?;
                Ok(XValue::Bool(match op {
                    RelOp::Lt => l < r,
                    RelOp::Le => l <= r,
                    RelOp::Gt => l > r,
                    RelOp::Ge => l >= r,
                }))
            }
            Expr::Add(left, right, minus) => {
                let l = self.number(left)?;
                let r = self.number(right)?;
                Ok(XValue::Num(if *minus { l - r } else { l + r }))
            }
            Expr::Mul(left, right, op) => {
                let l = self.number(left)?;
                let r = self.number(right)?;
                Ok(XValue::Num(match op {
                    MulOp::Mul => l * r,
                    MulOp::Div => l / r,
                    MulOp::Mod => l % r,
                }))
            }
            Expr::Neg(inner) => Ok(XValue::Num(-self.number(inner)?)),
            Expr::Union(items) => {
                let mut nodes = Vec::new();
                for item in items {
                    nodes.extend(self.nodes(item)?);
                }
                let store = self.store.borrow();
                Ok(XValue::Nodes(unique_doc_order(&store, nodes)))
            }
            Expr::Path(absolute, steps) => self.eval_path(*absolute, steps),
            Expr::From(primary, steps) => {
                let nodes = self.nodes(primary)?;
                self.eval_from_nodes(nodes, steps)
            }
            Expr::Filter(primary, preds) => {
                let nodes = self.nodes(primary)?;
                Ok(XValue::Nodes(self.apply_preds(nodes, preds)?))
            }
            Expr::Literal(text) => Ok(XValue::Str(text.clone())),
            Expr::Number(n) => Ok(XValue::Num(*n)),
            Expr::Var(name) => self.variables.get(name).cloned().ok_or_else(|| format!("Unbound variable: {name}")),
            Expr::Call(name, args) => self.call(name, args),
        }
    }

    fn eval_path(&mut self, absolute: bool, steps: &[Step]) -> Result<XValue, String> {
        let start = if absolute { self.document() } else { self.node };
        if absolute && steps.is_empty() {
            return Ok(XValue::Nodes(vec![start]));
        }
        self.eval_from_nodes(vec![start], steps)
    }

    fn eval_from_nodes(&mut self, mut current: Vec<u32>, steps: &[Step]) -> Result<XValue, String> {
        for step in steps {
            if step.axis == Axis::Namespace {
                let mut nss = Vec::new();
                {
                    let store = self.store.borrow();
                    for node in &current {
                        for ns in namespace_axis(&store, *node) {
                            if namespace_test(&store, ns, &step.test) {
                                nss.push(ns);
                            }
                        }
                    }
                }
                nss.sort_unstable();
                nss.dedup();
                return Ok(XValue::Nss(nss));
            }
            let mut next = Vec::new();
            for node in current {
                let mut matches = self.axis_nodes(node, step.axis);
                matches.retain(|candidate| self.matches(*candidate, &step.test, step.axis));
                matches = self.apply_preds(matches, &step.preds)?;
                next.extend(matches);
            }
            let store = self.store.borrow();
            current = unique_doc_order(&store, next);
        }
        Ok(XValue::Nodes(current))
    }

    fn document(&self) -> u32 {
        self.store.borrow().nodes[self.node as usize].owner
    }

    fn axis_nodes(&self, node: u32, axis: Axis) -> Vec<u32> {
        let store = self.store.borrow();
        match axis {
            Axis::Child => store.nodes[node as usize].children.clone(),
            Axis::Attribute => store.nodes[node as usize].attrs.clone(),
            Axis::Self_ => vec![node],
            Axis::Parent => store.nodes[node as usize].parent.into_iter().collect(),
            Axis::Descendant => descendants(&store, node, false),
            Axis::DescendantOrSelf => descendants(&store, node, true),
            Axis::Ancestor => ancestors(&store, node, false),
            Axis::AncestorOrSelf => ancestors(&store, node, true),
            Axis::FollowingSibling => siblings(&store, node, true),
            Axis::PrecedingSibling => siblings(&store, node, false),
            Axis::Following => following(&store, node),
            Axis::Preceding => preceding(&store, node),
            Axis::Namespace => Vec::new(),
        }
    }

    fn matches(&self, id: u32, test: &NodeTest, axis: Axis) -> bool {
        let store = self.store.borrow();
        let kind = store.nodes[id as usize].kind;
        match test {
            NodeTest::Node => !matches!(axis, Axis::Attribute) || kind == ATTRIBUTE,
            NodeTest::Text => matches!(kind, TEXT | CDATA),
            NodeTest::Comment => kind == COMMENT,
            NodeTest::Pi(target) => kind == PI && target.as_ref().map(|name| store.nodes[id as usize].name.as_deref() == Some(name)).unwrap_or(true),
            NodeTest::Name { prefix, local } => self.match_name(&store, id, kind, axis, prefix, local),
        }
    }

    fn match_name(&self, store: &Store, id: u32, kind: i32, axis: Axis, prefix: &Option<String>, local: &Option<String>) -> bool {
        let principal = if matches!(axis, Axis::Attribute) { kind == ATTRIBUTE } else { kind == ELEMENT };
        if !principal {
            return false;
        }
        if let Some(local) = local {
            if store.nodes[id as usize].name.as_deref() != Some(local) {
                return false;
            }
        }
        match prefix {
            None if local.is_none() => true,
            None => store.nodes[id as usize].ns.is_none(),
            Some(prefix) => {
                let href = if prefix.is_empty() {
                    self.namespaces.get("").map(String::as_str)
                } else if prefix == "xml" {
                    Some(crate::store::XML_NS)
                } else {
                    self.namespaces.get(prefix).map(String::as_str)
                };
                let Some(href) = href else {
                    return false;
                };
                store.nodes[id as usize].ns.is_some_and(|ns| store.nss[ns as usize].href == href)
            }
        }
    }

    fn apply_preds(&mut self, nodes: Vec<u32>, preds: &[Expr]) -> Result<Vec<u32>, String> {
        let mut nodes = nodes;
        for pred in preds {
            let size = nodes.len();
            let mut kept = Vec::new();
            for (index, node) in nodes.iter().copied().enumerate() {
                let saved = (self.node, self.position, self.size);
                self.node = node;
                self.position = index + 1;
                self.size = size;
                let pass = match self.eval(pred)? {
                    XValue::Num(n) => n == self.position as f64,
                    other => truth(&other),
                };
                self.node = saved.0;
                self.position = saved.1;
                self.size = saved.2;
                if pass {
                    kept.push(node);
                }
            }
            nodes = kept;
        }
        Ok(nodes)
    }

    fn bool(&mut self, expr: &Expr) -> Result<bool, String> {
        Ok(truth(&self.eval(expr)?))
    }

    fn number(&mut self, expr: &Expr) -> Result<f64, String> {
        let value = self.eval(expr)?;
        let store = self.store.borrow();
        Ok(to_number(&value, &store))
    }

    fn string(&mut self, expr: &Expr) -> Result<String, String> {
        let value = self.eval(expr)?;
        let store = self.store.borrow();
        Ok(to_string(&value, &store))
    }

    fn nodes(&mut self, expr: &Expr) -> Result<Vec<u32>, String> {
        match self.eval(expr)? {
            XValue::Nodes(nodes) => Ok(nodes),
            _ => Ok(Vec::new()),
        }
    }

    fn equal(&mut self, left: &Expr, right: &Expr) -> Result<bool, String> {
        let l = self.eval(left)?;
        let r = self.eval(right)?;
        let store = self.store.borrow();
        Ok(values_equal(&l, &r, &store))
    }

    fn call(&mut self, name: &str, args: &[Expr]) -> Result<XValue, String> {
        match name {
            "true" => Ok(XValue::Bool(true)),
            "false" => Ok(XValue::Bool(false)),
            "not" => Ok(XValue::Bool(!self.bool(&args[0])?)),
            "boolean" => Ok(XValue::Bool(self.bool(&args[0])?)),
            "number" => {
                if args.is_empty() {
                    let store = self.store.borrow();
                    Ok(XValue::Num(to_number(&XValue::Nodes(vec![self.node]), &store)))
                } else {
                    Ok(XValue::Num(self.number(&args[0])?))
                }
            }
            "string" => {
                if args.is_empty() {
                    let store = self.store.borrow();
                    Ok(XValue::Str(store.text_content(self.node)))
                } else {
                    Ok(XValue::Str(self.string(&args[0])?))
                }
            }
            "contains" => Ok(XValue::Bool(self.string(&args[0])?.contains(&self.string(&args[1])?))),
            "starts-with" => Ok(XValue::Bool(self.string(&args[0])?.starts_with(&self.string(&args[1])?))),
            "concat" => {
                let mut out = String::new();
                for arg in args {
                    out.push_str(&self.string(arg)?);
                }
                Ok(XValue::Str(out))
            }
            "normalize-space" => {
                let text = if args.is_empty() {
                    let store = self.store.borrow();
                    store.text_content(self.node)
                } else {
                    self.string(&args[0])?
                };
                Ok(XValue::Str(normalize_space(&text)))
            }
            "string-length" => {
                let text = if args.is_empty() {
                    let store = self.store.borrow();
                    store.text_content(self.node)
                } else {
                    self.string(&args[0])?
                };
                Ok(XValue::Num(text.chars().count() as f64))
            }
            "substring" => {
                let text = self.string(&args[0])?;
                let start = self.number(&args[1])?.round() as isize;
                let chars: Vec<char> = text.chars().collect();
                let from = (start - 1).max(0) as usize;
                let slice = if args.len() > 2 {
                    let len = self.number(&args[2])?.round().max(0.0) as usize;
                    chars.into_iter().skip(from).take(len).collect()
                } else {
                    chars.into_iter().skip(from).collect()
                };
                Ok(XValue::Str(slice))
            }
            "substring-before" => {
                let text = self.string(&args[0])?;
                let needle = self.string(&args[1])?;
                Ok(XValue::Str(text.split_once(&needle).map(|(head, _)| head.to_string()).unwrap_or_default()))
            }
            "substring-after" => {
                let text = self.string(&args[0])?;
                let needle = self.string(&args[1])?;
                Ok(XValue::Str(text.split_once(&needle).map(|(_, tail)| tail.to_string()).unwrap_or_default()))
            }
            "translate" => Ok(XValue::Str(translate(&self.string(&args[0])?, &self.string(&args[1])?, &self.string(&args[2])?))),
            "count" => Ok(XValue::Num(self.nodes(&args[0])?.len() as f64)),
            "sum" => {
                let nodes = self.nodes(&args[0])?;
                let store = self.store.borrow();
                let mut total = 0.0;
                for node in nodes {
                    total += to_number(&XValue::Str(store.text_content(node)), &store);
                }
                Ok(XValue::Num(total))
            }
            "position" => Ok(XValue::Num(self.position as f64)),
            "last" => Ok(XValue::Num(self.size as f64)),
            "floor" => Ok(XValue::Num(self.number(&args[0])?.floor())),
            "ceiling" => Ok(XValue::Num(self.number(&args[0])?.ceil())),
            "round" => {
                let number = self.number(&args[0])?;
                // XPath 1.0 rounds ties toward positive infinity.
                Ok(XValue::Num((number + 0.5).floor()))
            }
            "local-name" => {
                let node = if args.is_empty() { self.node } else { self.nodes(&args[0])?.into_iter().next().unwrap_or(self.node) };
                let store = self.store.borrow();
                Ok(XValue::Str(store.local_name(node)))
            }
            "name" => {
                let node = if args.is_empty() { self.node } else { self.nodes(&args[0])?.into_iter().next().unwrap_or(self.node) };
                let store = self.store.borrow();
                Ok(XValue::Str(store.qualified_name(node)))
            }
            "namespace-uri" => {
                let node = if args.is_empty() { self.node } else { self.nodes(&args[0])?.into_iter().next().unwrap_or(self.node) };
                let store = self.store.borrow();
                let href = store.nodes[node as usize].ns.map(|ns| store.nss[ns as usize].href.clone()).unwrap_or_default();
                Ok(XValue::Str(href))
            }
            "id" => self.call_id(args),
            "nokogiri-builtin:css-class" => self.call_css_class(args),
            "nokogiri-builtin:local-name-is" => self.call_local_name_is(args),
            other => self.call_custom(other, args),
        }
    }

    fn call_id(&mut self, args: &[Expr]) -> Result<XValue, String> {
        if args.len() != 1 {
            return Err("xmlXPathCompOpEval: function id not found".to_string());
        }
        let text = self.string(&args[0])?;
        let tokens: Vec<&str> = text.split_whitespace().collect();
        let store = self.store.borrow();
        let root = store.nodes[self.node as usize].owner;
        let mut nodes = Vec::new();
        collect_ids(&store, root, &tokens, &mut nodes);
        Ok(XValue::Nodes(unique_doc_order(&store, nodes)))
    }

    fn call_css_class(&mut self, args: &[Expr]) -> Result<XValue, String> {
        if args.len() != 2 {
            return Err("Invalid number of arguments: css-class".to_string());
        }
        let hay = self.string(&args[0])?;
        let needle = self.string(&args[1])?;
        Ok(XValue::Bool(css_class_match(&hay, &needle)))
    }

    fn call_local_name_is(&mut self, args: &[Expr]) -> Result<XValue, String> {
        if args.len() != 1 {
            return Err("Invalid number of arguments: local-name-is".to_string());
        }
        let expected = self.string(&args[0])?;
        let store = self.store.borrow();
        Ok(XValue::Bool(store.local_name(self.node) == expected))
    }

    fn call_custom(&mut self, name: &str, args: &[Expr]) -> Result<XValue, String> {
        let mut values = Vec::with_capacity(args.len());
        for arg in args {
            values.push(self.eval(arg)?);
        }
        if let Some(functions) = self.functions.as_mut() {
            if let Some(value) = functions(name, &values)? {
                return Ok(value);
            }
        }
        Err(format!("xmlXPathCompOpEval: function {name} not found"))
    }
}

fn collect_ids(store: &Store, id: u32, tokens: &[&str], out: &mut Vec<u32>) {
    let kind = store.nodes[id as usize].kind;
    if kind == ELEMENT {
        let attrs = store.nodes[id as usize].attrs.clone();
        for attr in attrs {
            let attribute = &store.nodes[attr as usize];
            let Some(name) = attribute.name.as_deref() else { continue };
            if name != "id" {
                continue;
            }
            if tokens.iter().any(|token| attribute.content == *token) {
                out.push(id);
                break;
            }
        }
    }
    let children = store.nodes[id as usize].children.clone();
    for child in children {
        collect_ids(store, child, tokens, out);
    }
}

fn css_class_match(hay: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    let hay = hay.as_bytes();
    let needle = needle.as_bytes();
    let mut index = 0;
    while index < hay.len() {
        if hay[index..].starts_with(needle) {
            let next = index + needle.len();
            if next == hay.len() || is_xpath_blank(hay[next]) {
                return true;
            }
        }
        while index < hay.len() && !is_xpath_blank(hay[index]) {
            index += 1;
        }
        while index < hay.len() && is_xpath_blank(hay[index]) {
            index += 1;
        }
    }
    false
}

fn is_xpath_blank(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\r')
}

fn descendants(store: &Store, id: u32, include_self: bool) -> Vec<u32> {
    let mut out = Vec::new();
    if include_self {
        out.push(id);
    }
    fn walk(store: &Store, id: u32, out: &mut Vec<u32>) {
        for child in &store.nodes[id as usize].children {
            out.push(*child);
            walk(store, *child, out);
        }
    }
    walk(store, id, &mut out);
    out
}

fn ancestors(store: &Store, mut id: u32, include_self: bool) -> Vec<u32> {
    let mut out = Vec::new();
    if include_self {
        out.push(id);
    }
    while let Some(parent) = store.nodes[id as usize].parent {
        out.push(parent);
        id = parent;
    }
    out
}

fn siblings(store: &Store, id: u32, following: bool) -> Vec<u32> {
    let Some(parent) = store.nodes[id as usize].parent else {
        return Vec::new();
    };
    let children = &store.nodes[parent as usize].children;
    let Some(index) = children.iter().position(|child| *child == id) else {
        return Vec::new();
    };
    if following {
        children[index + 1..].to_vec()
    } else {
        children[..index].iter().rev().copied().collect()
    }
}

fn following(store: &Store, id: u32) -> Vec<u32> {
    let mut out = Vec::new();
    let mut current = id;
    while let Some(parent) = store.nodes[current as usize].parent {
        let after = siblings(store, current, true);
        for sibling in after {
            out.push(sibling);
            out.extend(descendants(store, sibling, false));
        }
        current = parent;
    }
    out
}

fn preceding(store: &Store, id: u32) -> Vec<u32> {
    let mut out = Vec::new();
    let mut current = id;
    while let Some(parent) = store.nodes[current as usize].parent {
        let before = siblings(store, current, false);
        for sibling in before {
            out.extend(descendants(store, sibling, false).into_iter().rev());
            out.push(sibling);
        }
        current = parent;
    }
    out.reverse();
    out
}

fn unique_doc_order(store: &Store, mut nodes: Vec<u32>) -> Vec<u32> {
    nodes.sort_by(|left, right| store.compare(*left, *right).cmp(&0));
    nodes.dedup();
    nodes
}

fn sort_result(store: &Store, value: XValue) -> XValue {
    match value {
        XValue::Nodes(nodes) => XValue::Nodes(unique_doc_order(store, nodes)),
        other => other,
    }
}

fn truth(value: &XValue) -> bool {
    match value {
        XValue::Bool(v) => *v,
        XValue::Num(n) => *n != 0.0 && !n.is_nan(),
        XValue::Str(s) => !s.is_empty(),
        XValue::Nodes(nodes) => !nodes.is_empty(),
        XValue::Nss(nodes) => !nodes.is_empty(),
    }
}

fn namespace_axis(store: &Store, node: u32) -> Vec<u32> {
    let mut nss = store.namespace_scopes(node);
    if let Some(xml) = store.find_xml_ns() {
        if !nss.contains(&xml) {
            nss.push(xml);
        }
    }
    nss
}

fn namespace_test(store: &Store, ns: u32, test: &NodeTest) -> bool {
    match test {
        NodeTest::Node | NodeTest::Name { local: None, .. } => true,
        NodeTest::Name { local: Some(name), .. } => {
            store.nss[ns as usize].prefix.as_deref() == Some(name.as_str())
        }
        _ => false,
    }
}

fn to_number(value: &XValue, store: &Store) -> f64 {
    match value {
        XValue::Num(n) => *n,
        XValue::Bool(v) => {
            if *v {
                1.0
            } else {
                0.0
            }
        }
        XValue::Str(s) => s.trim().parse().unwrap_or(f64::NAN),
        XValue::Nodes(nodes) => nodes.first().map(|id| store.text_content(*id).trim().parse().unwrap_or(f64::NAN)).unwrap_or(f64::NAN),
        XValue::Nss(_) => f64::NAN,
    }
}

fn to_string(value: &XValue, store: &Store) -> String {
    match value {
        XValue::Str(s) => s.clone(),
        XValue::Bool(v) => {
            if *v {
                "true".to_string()
            } else {
                "false".to_string()
            }
        }
        XValue::Num(n) => {
            if n.fract() == 0.0 && n.is_finite() {
                format!("{}", *n as i64)
            } else {
                format!("{n}")
            }
        }
        XValue::Nodes(nodes) => nodes.first().map(|id| store.text_content(*id)).unwrap_or_default(),
        XValue::Nss(_) => String::new(),
    }
}

fn values_equal(left: &XValue, right: &XValue, store: &Store) -> bool {
    match (left, right) {
        (XValue::Nodes(nodes), other) | (other, XValue::Nodes(nodes)) => {
            if let XValue::Nodes(other_nodes) = other {
                return nodes.iter().any(|left_id| {
                    other_nodes.iter().any(|right_id| store.text_content(*left_id) == store.text_content(*right_id))
                });
            }
            let text = to_string(other, store);
            let number = matches!(other, XValue::Num(_));
            nodes.iter().any(|id| {
                if number {
                    store.text_content(*id).trim().parse::<f64>().ok() == Some(to_number(other, store))
                } else {
                    store.text_content(*id) == text
                }
            })
        }
        (XValue::Bool(_), _) | (_, XValue::Bool(_)) => truth(left) == truth(right),
        (XValue::Num(_), _) | (_, XValue::Num(_)) => to_number(left, store) == to_number(right, store),
        _ => to_string(left, store) == to_string(right, store),
    }
}

fn normalize_space(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn translate(text: &str, from: &str, to: &str) -> String {
    let from: Vec<char> = from.chars().collect();
    let to: Vec<char> = to.chars().collect();
    text.chars().filter_map(|ch| {
        if let Some(index) = from.iter().position(|item| *item == ch) {
            to.get(index).copied()
        } else {
            Some(ch)
        }
    }).collect()
}

pub fn check_prefixes(expr: &str, namespaces: &HashMap<String, String>) -> Result<(), String> {
    let mut parser = Parser::new(expr);
    scan_prefixes(&mut parser, namespaces)
}

fn scan_prefixes(parser: &mut Parser<'_>, namespaces: &HashMap<String, String>) -> Result<(), String> {
    let bytes = parser.s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\'' || bytes[i] == b'"' {
            let quote = bytes[i];
            i += 1;
            while i < bytes.len() && bytes[i] != quote {
                i += 1;
            }
            i += 1;
            continue;
        }
        if bytes[i] == b':' && i + 1 < bytes.len() && bytes[i + 1] != b':' && (i == 0 || bytes[i - 1] != b':') {
            let mut start = i;
            while start > 0 && (bytes[start - 1].is_ascii_alphanumeric() || bytes[start - 1] == b'_' || bytes[start - 1] == b'-') {
                start -= 1;
            }
            let prefix = &parser.s[start..i];
            if !prefix.is_empty() && prefix != "xml" && !namespaces.contains_key(prefix) {
                return Err(format!("Undefined namespace prefix: {prefix}"));
            }
            if prefix.is_empty() && !namespaces.contains_key("") {
                return Err("Undefined namespace prefix: ".to_string());
            }
        }
        i += 1;
    }
    Ok(())
}
