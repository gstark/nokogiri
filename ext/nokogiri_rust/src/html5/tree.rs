//! HTML5 tree constructor.
//!
//! Control flow follows `lib/nokogiri/pure/html5/tree_builder.rb`.
//! Node identity is the `Rc` pointer.

use std::cell::RefCell;
use std::rc::{Rc, Weak};

use super::model::{
    ascii_lower, eq_lower, ErrorLog, FormEntry, NodeKind, NodeRef, Ns, Options, Output, Status,
    TextKind, TokState, Token, TokenKind,
};
use super::quirks;

const KNOWN: &[&str] = &[
    "html",
    "head",
    "title",
    "base",
    "link",
    "meta",
    "style",
    "script",
    "noscript",
    "template",
    "body",
    "article",
    "section",
    "nav",
    "aside",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hgroup",
    "header",
    "footer",
    "address",
    "p",
    "hr",
    "pre",
    "blockquote",
    "ol",
    "ul",
    "li",
    "dl",
    "dt",
    "dd",
    "figure",
    "figcaption",
    "main",
    "div",
    "a",
    "em",
    "strong",
    "small",
    "s",
    "cite",
    "q",
    "dfn",
    "abbr",
    "data",
    "time",
    "code",
    "var",
    "samp",
    "kbd",
    "sub",
    "sup",
    "i",
    "b",
    "u",
    "mark",
    "ruby",
    "rt",
    "rp",
    "bdi",
    "bdo",
    "span",
    "br",
    "wbr",
    "ins",
    "del",
    "image",
    "img",
    "iframe",
    "embed",
    "object",
    "param",
    "video",
    "audio",
    "source",
    "track",
    "canvas",
    "map",
    "area",
    "math",
    "mi",
    "mo",
    "mn",
    "ms",
    "mtext",
    "mglyph",
    "malignmark",
    "annotation-xml",
    "svg",
    "foreignobject",
    "desc",
    "table",
    "caption",
    "colgroup",
    "col",
    "tbody",
    "thead",
    "tfoot",
    "tr",
    "td",
    "th",
    "form",
    "fieldset",
    "legend",
    "label",
    "input",
    "button",
    "select",
    "datalist",
    "optgroup",
    "option",
    "textarea",
    "keygen",
    "output",
    "progress",
    "meter",
    "details",
    "summary",
    "menu",
    "menuitem",
    "applet",
    "acronym",
    "bgsound",
    "dir",
    "frame",
    "frameset",
    "noframes",
    "listing",
    "xmp",
    "nextid",
    "noembed",
    "plaintext",
    "rb",
    "strike",
    "basefont",
    "big",
    "blink",
    "center",
    "font",
    "marquee",
    "multicol",
    "nobr",
    "spacer",
    "tt",
    "rtc",
    "dialog",
    "search",
];

const SVG_TAGS: &[(&str, &str)] = &[
    ("altglyph", "altGlyph"),
    ("altglyphdef", "altGlyphDef"),
    ("altglyphitem", "altGlyphItem"),
    ("animatecolor", "animateColor"),
    ("animatemotion", "animateMotion"),
    ("animatetransform", "animateTransform"),
    ("clippath", "clipPath"),
    ("feblend", "feBlend"),
    ("fecolormatrix", "feColorMatrix"),
    ("fecomponenttransfer", "feComponentTransfer"),
    ("fecomposite", "feComposite"),
    ("feconvolvematrix", "feConvolveMatrix"),
    ("fediffuselighting", "feDiffuseLighting"),
    ("fedisplacementmap", "feDisplacementMap"),
    ("fedistantlight", "feDistantLight"),
    ("feflood", "feFlood"),
    ("fefunca", "feFuncA"),
    ("fefuncb", "feFuncB"),
    ("fefuncg", "feFuncG"),
    ("fefuncr", "feFuncR"),
    ("fegaussianblur", "feGaussianBlur"),
    ("feimage", "feImage"),
    ("femerge", "feMerge"),
    ("femergenode", "feMergeNode"),
    ("femorphology", "feMorphology"),
    ("feoffset", "feOffset"),
    ("fepointlight", "fePointLight"),
    ("fespecularlighting", "feSpecularLighting"),
    ("fespotlight", "feSpotLight"),
    ("fetile", "feTile"),
    ("feturbulence", "feTurbulence"),
    ("foreignobject", "foreignObject"),
    ("glyphref", "glyphRef"),
    ("lineargradient", "linearGradient"),
    ("radialgradient", "radialGradient"),
    ("textpath", "textPath"),
];

const SVG_ATTRS: &[(&str, &str)] = &[
    ("attributename", "attributeName"),
    ("attributetype", "attributeType"),
    ("basefrequency", "baseFrequency"),
    ("baseprofile", "baseProfile"),
    ("calcmode", "calcMode"),
    ("clippathunits", "clipPathUnits"),
    ("diffuseconstant", "diffuseConstant"),
    ("edgemode", "edgeMode"),
    ("filterunits", "filterUnits"),
    ("glyphref", "glyphRef"),
    ("gradienttransform", "gradientTransform"),
    ("gradientunits", "gradientUnits"),
    ("kernelmatrix", "kernelMatrix"),
    ("kernelunitlength", "kernelUnitLength"),
    ("keypoints", "keyPoints"),
    ("keysplines", "keySplines"),
    ("keytimes", "keyTimes"),
    ("lengthadjust", "lengthAdjust"),
    ("limitingconeangle", "limitingConeAngle"),
    ("markerheight", "markerHeight"),
    ("markerunits", "markerUnits"),
    ("markerwidth", "markerWidth"),
    ("maskcontentunits", "maskContentUnits"),
    ("maskunits", "maskUnits"),
    ("numoctaves", "numOctaves"),
    ("pathlength", "pathLength"),
    ("patterncontentunits", "patternContentUnits"),
    ("patterntransform", "patternTransform"),
    ("patternunits", "patternUnits"),
    ("pointsatx", "pointsAtX"),
    ("pointsaty", "pointsAtY"),
    ("pointsatz", "pointsAtZ"),
    ("preservealpha", "preserveAlpha"),
    ("preserveaspectratio", "preserveAspectRatio"),
    ("primitiveunits", "primitiveUnits"),
    ("refx", "refX"),
    ("refy", "refY"),
    ("repeatcount", "repeatCount"),
    ("repeatdur", "repeatDur"),
    ("requiredextensions", "requiredExtensions"),
    ("requiredfeatures", "requiredFeatures"),
    ("specularconstant", "specularConstant"),
    ("specularexponent", "specularExponent"),
    ("spreadmethod", "spreadMethod"),
    ("startoffset", "startOffset"),
    ("stddeviation", "stdDeviation"),
    ("stitchtiles", "stitchTiles"),
    ("surfacescale", "surfaceScale"),
    ("systemlanguage", "systemLanguage"),
    ("tablevalues", "tableValues"),
    ("targetx", "targetX"),
    ("targety", "targetY"),
    ("textlength", "textLength"),
    ("viewbox", "viewBox"),
    ("viewtarget", "viewTarget"),
    ("xchannelselector", "xChannelSelector"),
    ("ychannelselector", "yChannelSelector"),
    ("zoomandpan", "zoomAndPan"),
];

const FOREIGN_ATTRS: &[(&str, &str, Ns)] = &[
    ("xlink:actuate", "actuate", Ns::Xlink),
    ("xlink:arcrole", "arcrole", Ns::Xlink),
    ("xlink:href", "href", Ns::Xlink),
    ("xlink:role", "role", Ns::Xlink),
    ("xlink:show", "show", Ns::Xlink),
    ("xlink:title", "title", Ns::Xlink),
    ("xlink:type", "type", Ns::Xlink),
    ("xml:lang", "lang", Ns::Xml),
    ("xml:space", "space", Ns::Xml),
    ("xmlns", "xmlns", Ns::Xmlns),
    ("xmlns:xlink", "xlink", Ns::Xmlns),
];

const HEADING: &[&str] = &["h1", "h2", "h3", "h4", "h5", "h6"];
const DD_DT: &[&str] = &["dd", "dt"];
const TD_TH: &[&str] = &["td", "th"];
const IMPLIED: &[&str] = &[
    "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc",
];
const IMPLIED_THOROUGH: &[&str] = &[
    "caption", "colgroup", "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc",
    "tbody", "td", "tfoot", "th", "thead", "tr",
];
const CLOSABLE: &[&str] = &[
    "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc", "tbody", "td", "tfoot",
    "th", "thead", "tr", "body", "html",
];
const BLOCK_START: &[&str] = &[
    "address",
    "article",
    "aside",
    "blockquote",
    "center",
    "details",
    "dialog",
    "dir",
    "div",
    "dl",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "header",
    "hgroup",
    "main",
    "menu",
    "nav",
    "ol",
    "p",
    "section",
    "summary",
    "ul",
    "search",
];
const BLOCK_END: &[&str] = &[
    "address",
    "article",
    "aside",
    "blockquote",
    "button",
    "center",
    "details",
    "dialog",
    "dir",
    "div",
    "dl",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "header",
    "hgroup",
    "listing",
    "main",
    "menu",
    "nav",
    "ol",
    "pre",
    "section",
    "summary",
    "ul",
    "search",
];
const FORMAT_START: &[&str] = &[
    "b", "big", "code", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u",
];
const FORMAT_END: &[&str] = &[
    "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u",
];
const HEAD_ELS: &[&str] = &[
    "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template",
    "title",
];
const VOID_BODY: &[&str] = &["area", "br", "embed", "img", "image", "keygen", "wbr"];
const TABLE_END_BANS: &[&str] = &[
    "body", "caption", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr",
];
const CELL_START_CLOSE: &[&str] = &[
    "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr",
];
const SELECT_TABLE: &[&str] = &[
    "caption", "table", "tbody", "tfoot", "thead", "tr", "td", "th",
];
const FOREIGN_BREAK_START: &[&str] = &[
    "b",
    "big",
    "blockquote",
    "body",
    "br",
    "center",
    "code",
    "dd",
    "div",
    "dl",
    "dt",
    "em",
    "embed",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "head",
    "hr",
    "i",
    "img",
    "li",
    "listing",
    "menu",
    "meta",
    "nobr",
    "ol",
    "p",
    "pre",
    "ruby",
    "s",
    "small",
    "span",
    "strong",
    "strike",
    "sub",
    "sup",
    "table",
    "tt",
    "u",
    "ul",
    "var",
];
const MATH_TEXT: &[&str] = &["mi", "mo", "mn", "ms", "mtext"];
const ADDRESS_DIV_P: &[&str] = &["address", "div", "p"];
const APPLET_MARQUEE_OBJECT: &[&str] = &["applet", "marquee", "object"];
const BASE_LINK: &[&str] = &["base", "basefont", "bgsound", "link"];
const HEAD_BODY_HTML_BR: &[&str] = &["head", "body", "html", "br"];
const BODY_HTML_BR: &[&str] = &["body", "html", "br"];
const TBODY_GROUP: &[&str] = &["tbody", "tfoot", "thead"];
const PRE_LISTING: &[&str] = &["pre", "listing"];
const MGLYPH_MARK: &[&str] = &["mglyph", "malignmark"];
const SVG_HTML_BREAK: &[&str] = &["foreignobject", "desc", "title"];

const DEFAULT_SCOPE: &[(Ns, &str)] = &[
    (Ns::Html, "applet"),
    (Ns::Html, "caption"),
    (Ns::Html, "html"),
    (Ns::Html, "table"),
    (Ns::Html, "td"),
    (Ns::Html, "th"),
    (Ns::Html, "marquee"),
    (Ns::Html, "object"),
    (Ns::Html, "template"),
    (Ns::MathMl, "mi"),
    (Ns::MathMl, "mo"),
    (Ns::MathMl, "mn"),
    (Ns::MathMl, "ms"),
    (Ns::MathMl, "mtext"),
    (Ns::MathMl, "annotation-xml"),
    (Ns::Svg, "foreignobject"),
    (Ns::Svg, "desc"),
    (Ns::Svg, "title"),
];
const LIST_SCOPE: &[(Ns, &str)] = &[
    (Ns::Html, "applet"),
    (Ns::Html, "caption"),
    (Ns::Html, "html"),
    (Ns::Html, "table"),
    (Ns::Html, "td"),
    (Ns::Html, "th"),
    (Ns::Html, "marquee"),
    (Ns::Html, "object"),
    (Ns::Html, "template"),
    (Ns::MathMl, "mi"),
    (Ns::MathMl, "mo"),
    (Ns::MathMl, "mn"),
    (Ns::MathMl, "ms"),
    (Ns::MathMl, "mtext"),
    (Ns::MathMl, "annotation-xml"),
    (Ns::Svg, "foreignobject"),
    (Ns::Svg, "desc"),
    (Ns::Svg, "title"),
    (Ns::Html, "ol"),
    (Ns::Html, "ul"),
];
const BUTTON_SCOPE: &[(Ns, &str)] = &[
    (Ns::Html, "applet"),
    (Ns::Html, "caption"),
    (Ns::Html, "html"),
    (Ns::Html, "table"),
    (Ns::Html, "td"),
    (Ns::Html, "th"),
    (Ns::Html, "marquee"),
    (Ns::Html, "object"),
    (Ns::Html, "template"),
    (Ns::MathMl, "mi"),
    (Ns::MathMl, "mo"),
    (Ns::MathMl, "mn"),
    (Ns::MathMl, "ms"),
    (Ns::MathMl, "mtext"),
    (Ns::MathMl, "annotation-xml"),
    (Ns::Svg, "foreignobject"),
    (Ns::Svg, "desc"),
    (Ns::Svg, "title"),
    (Ns::Html, "button"),
];
const TABLE_SCOPE: &[(Ns, &str)] = &[
    (Ns::Html, "html"),
    (Ns::Html, "table"),
    (Ns::Html, "template"),
];
const SELECT_SCOPE: &[(Ns, &str)] = &[(Ns::Html, "optgroup"), (Ns::Html, "option")];
const OPEN_SCOPE: &[(Ns, &str)] = &[(Ns::Html, "html")];
const SPECIAL: &[(Ns, &str)] = &[
    (Ns::Html, "address"),
    (Ns::Html, "applet"),
    (Ns::Html, "area"),
    (Ns::Html, "article"),
    (Ns::Html, "aside"),
    (Ns::Html, "base"),
    (Ns::Html, "basefont"),
    (Ns::Html, "bgsound"),
    (Ns::Html, "blockquote"),
    (Ns::Html, "body"),
    (Ns::Html, "br"),
    (Ns::Html, "button"),
    (Ns::Html, "caption"),
    (Ns::Html, "center"),
    (Ns::Html, "col"),
    (Ns::Html, "colgroup"),
    (Ns::Html, "dd"),
    (Ns::Html, "details"),
    (Ns::Html, "dir"),
    (Ns::Html, "div"),
    (Ns::Html, "dl"),
    (Ns::Html, "dt"),
    (Ns::Html, "embed"),
    (Ns::Html, "fieldset"),
    (Ns::Html, "figcaption"),
    (Ns::Html, "figure"),
    (Ns::Html, "footer"),
    (Ns::Html, "form"),
    (Ns::Html, "frame"),
    (Ns::Html, "frameset"),
    (Ns::Html, "h1"),
    (Ns::Html, "h2"),
    (Ns::Html, "h3"),
    (Ns::Html, "h4"),
    (Ns::Html, "h5"),
    (Ns::Html, "h6"),
    (Ns::Html, "head"),
    (Ns::Html, "header"),
    (Ns::Html, "hgroup"),
    (Ns::Html, "hr"),
    (Ns::Html, "html"),
    (Ns::Html, "iframe"),
    (Ns::Html, "img"),
    (Ns::Html, "input"),
    (Ns::Html, "li"),
    (Ns::Html, "link"),
    (Ns::Html, "listing"),
    (Ns::Html, "marquee"),
    (Ns::Html, "menu"),
    (Ns::Html, "meta"),
    (Ns::Html, "nav"),
    (Ns::Html, "noembed"),
    (Ns::Html, "noframes"),
    (Ns::Html, "noscript"),
    (Ns::Html, "object"),
    (Ns::Html, "ol"),
    (Ns::Html, "p"),
    (Ns::Html, "param"),
    (Ns::Html, "plaintext"),
    (Ns::Html, "pre"),
    (Ns::Html, "script"),
    (Ns::Html, "section"),
    (Ns::Html, "select"),
    (Ns::Html, "style"),
    (Ns::Html, "summary"),
    (Ns::Html, "table"),
    (Ns::Html, "tbody"),
    (Ns::Html, "td"),
    (Ns::Html, "template"),
    (Ns::Html, "textarea"),
    (Ns::Html, "tfoot"),
    (Ns::Html, "th"),
    (Ns::Html, "thead"),
    (Ns::Html, "tr"),
    (Ns::Html, "ul"),
    (Ns::Html, "wbr"),
    (Ns::Html, "xmp"),
    (Ns::MathMl, "mi"),
    (Ns::MathMl, "mo"),
    (Ns::MathMl, "mn"),
    (Ns::MathMl, "ms"),
    (Ns::MathMl, "mtext"),
    (Ns::MathMl, "annotation-xml"),
    (Ns::Svg, "foreignobject"),
    (Ns::Svg, "desc"),
    (Ns::Svg, "title"),
    (Ns::Html, "title"),
];
const TABLE_CONTEXT: &[(Ns, &str)] = &[
    (Ns::Html, "html"),
    (Ns::Html, "table"),
    (Ns::Html, "template"),
];
const TABLE_BODY_CONTEXT: &[(Ns, &str)] = &[
    (Ns::Html, "html"),
    (Ns::Html, "tbody"),
    (Ns::Html, "tfoot"),
    (Ns::Html, "thead"),
    (Ns::Html, "template"),
];
const TABLE_ROW_CONTEXT: &[(Ns, &str)] =
    &[(Ns::Html, "html"), (Ns::Html, "tr"), (Ns::Html, "template")];
const TABLE_TEXT_NODES: &[(Ns, &str)] = &[
    (Ns::Html, "table"),
    (Ns::Html, "tbody"),
    (Ns::Html, "template"),
    (Ns::Html, "tfoot"),
    (Ns::Html, "thead"),
    (Ns::Html, "tr"),
];
const FOSTER_TARGETS: &[(Ns, &str)] = &[
    (Ns::Html, "table"),
    (Ns::Html, "tbody"),
    (Ns::Html, "tfoot"),
    (Ns::Html, "thead"),
    (Ns::Html, "tr"),
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Initial,
    BeforeHtml,
    BeforeHead,
    InHead,
    InHeadNoscript,
    AfterHead,
    InBody,
    Text,
    InTable,
    InTableText,
    InCaption,
    InColumnGroup,
    InTableBody,
    InRow,
    InCell,
    InSelect,
    InSelectInTable,
    InTemplate,
    AfterBody,
    InFrameset,
    AfterFrameset,
    AfterAfterBody,
    AfterAfterFrameset,
}

type Attrs = Vec<(String, String, Option<Ns>)>;

pub fn parse(input: &str, options: &crate::html5::model::Options) -> crate::html5::model::Output {
    let mut builder = Builder::new(input, options);
    builder.parse()
}

struct Builder {
    tokenizer: crate::html5::lex::Tokenizer,
    errors: Rc<RefCell<ErrorLog>>,
    document: NodeRef,
    root: Option<NodeRef>,
    open: Vec<NodeRef>,
    formatting: Vec<FormEntry>,
    template_modes: Vec<Mode>,
    mode: Mode,
    original_mode: Mode,
    head: Option<NodeRef>,
    form: Option<NodeRef>,
    fragment_ctx: Option<NodeRef>,
    fragment_context: Option<String>,
    fragment_ns: Ns,
    fragment_encoding: Option<String>,
    fragment_quirks: i32,
    form_ancestor: bool,
    noscript_as_text: bool,
    max_tree_depth: i64,
    reprocess: bool,
    ack: bool,
    frameset_ok: bool,
    ignore_lf: bool,
    foster: bool,
    text: String,
    text_kind: TextKind,
    text_line: Option<i32>,
    table_tokens: Vec<Token>,
    current: Option<Token>,
    tree_too_deep: bool,
}

impl Builder {
    fn new(input: &str, options: &Options) -> Self {
        let errors = Rc::new(RefCell::new(ErrorLog::new(options.max_errors)));
        let tokenizer =
            crate::html5::lex::Tokenizer::new(input, errors.clone(), options.max_attributes);
        Self {
            tokenizer,
            errors,
            document: NodeRef::new(NodeKind::Document),
            root: None,
            open: Vec::new(),
            formatting: Vec::new(),
            template_modes: Vec::new(),
            mode: Mode::Initial,
            original_mode: Mode::Initial,
            head: None,
            form: None,
            fragment_ctx: None,
            fragment_context: options.fragment_context.clone(),
            fragment_ns: options.fragment_namespace,
            fragment_encoding: options.fragment_encoding.clone(),
            fragment_quirks: options.quirks_mode,
            form_ancestor: options.form_ancestor,
            noscript_as_text: options.noscript_as_text,
            max_tree_depth: options.max_tree_depth,
            reprocess: false,
            ack: false,
            frameset_ok: true,
            ignore_lf: false,
            foster: false,
            text: String::new(),
            text_kind: TextKind::Whitespace,
            text_line: None,
            table_tokens: Vec::new(),
            current: None,
            tree_too_deep: false,
        }
    }

    fn parse(&mut self) -> Output {
        if self.fragment_context.is_some() {
            self.init_fragment();
        }
        loop {
            let token = if self.reprocess {
                self.reprocess = false;
                self.current
                    .clone()
                    .unwrap_or_else(|| Token::blank(TokenKind::Eof))
            } else {
                let adjusted = self.adjusted_current();
                let foreign = adjusted
                    .as_ref()
                    .map(|node| node.0.borrow().namespace != Ns::Html)
                    .unwrap_or(false);
                self.tokenizer.set_foreign(foreign);
                if self.depth_exceeded() {
                    self.tree_too_deep = true;
                    self.eof_token()
                } else {
                    self.tokenizer.next_token()
                }
            };
            self.current = Some(token.clone());
            self.ack = false;
            if self.ignore_lf {
                let drop_lf = token.kind == TokenKind::Whitespace && text_of(&token) == "\n";
                self.ignore_lf = false;
                if drop_lf {
                    continue;
                }
            }
            self.handle_token(&token);
            if !self.reprocess
                && token.kind == TokenKind::StartTag
                && token.self_closing
                && !self.ack
            {
                self.add_solidus_error(&token);
            }
            if token.kind == TokenKind::Eof && !self.reprocess {
                break;
            }
        }
        self.finish_parsing();
        let status = if self.tree_too_deep {
            Status::TreeTooDeep
        } else if self.tokenizer.too_many_attributes() {
            Status::TooManyAttributes
        } else {
            Status::Ok
        };
        let quirks_mode = self.document.0.borrow().quirks_mode;
        let errors = self.errors.borrow().errors.clone();
        Output {
            document: self.document.clone(),
            root: self.root.clone(),
            errors,
            quirks_mode,
            status,
        }
    }

    fn depth_exceeded(&self) -> bool {
        self.max_tree_depth >= 0 && self.open.len() as i64 > self.max_tree_depth
    }

    fn eof_token(&self) -> Token {
        let mut token = Token::blank(TokenKind::Eof);
        if let Some(current) = &self.current {
            token.line = current.line;
            token.column = current.column;
            token.byte_offset = current.byte_offset;
        }
        token
    }

    fn init_fragment(&mut self) {
        let raw = self.fragment_context.clone().unwrap_or_default();
        let key = ascii_lower(&raw);
        let name = if known(&key) { key.clone() } else { raw };
        self.fragment_ctx = Some(make_element(&name, self.fragment_ns, Vec::new(), 0));
        if let Some(encoding) = &self.fragment_encoding {
            if let Some(ctx) = &self.fragment_ctx {
                ctx.0
                    .borrow_mut()
                    .attrs
                    .push(("encoding".to_string(), encoding.clone(), None));
            }
        }
        self.document.0.borrow_mut().quirks_mode = self.fragment_quirks;
        if self.fragment_ns == Ns::Html {
            self.tokenizer
                .set_state(fragment_state(&key, self.noscript_as_text));
        }
        let html = make_element("html", Ns::Html, Vec::new(), 0);
        let html = self.insert_element(html);
        self.root = Some(html);
        if key == "template" {
            self.template_modes.push(Mode::InTemplate);
        }
        self.reset_mode();
        if self.form_ancestor || (key == "form" && self.fragment_ns == Ns::Html) {
            self.form = Some(make_element("form", Ns::Html, Vec::new(), 0));
        }
    }

    fn current_node(&self) -> Option<NodeRef> {
        self.open.last().cloned()
    }

    fn adjusted_current(&self) -> Option<NodeRef> {
        if self.open.len() == 1 {
            if let Some(ctx) = &self.fragment_ctx {
                return Some(ctx.clone());
            }
        }
        self.current_node()
    }

    fn add_error(&self, token: &Token) {
        let message = self.error_message(token);
        self.errors.borrow_mut().add(
            "generic-parser",
            message,
            token.line,
            token.column,
            token.byte_offset,
        );
    }

    fn add_solidus_error(&self, token: &Token) {
        self.errors.borrow_mut().add(
            "non-void-html-element-start-tag-with-trailing-solidus",
            "Start tag of nonvoid HTML element ends with '/>', use '>'.".to_string(),
            token.line,
            token.column,
            token.byte_offset,
        );
    }

    fn tag_stack_message(&self) -> String {
        let names: Vec<String> = self.open.iter().map(node_error_name).collect();
        format!(" Currently open tags: {}.", names.join(", "))
    }

    fn error_message(&self, token: &Token) -> String {
        if self.mode == Mode::Initial && token.kind != TokenKind::Doctype {
            return "Expected a doctype token".to_string();
        }
        match token.kind {
            TokenKind::Doctype => "This is not a legal doctype".to_string(),
            TokenKind::Comment => "Comments aren't legal here".to_string(),
            TokenKind::Cdata | TokenKind::Whitespace | TokenKind::Character => {
                "Character tokens aren't legal here".to_string()
            }
            TokenKind::Null => "Null bytes are not allowed in HTML5".to_string(),
            TokenKind::Eof => {
                if self.mode == Mode::Initial {
                    "You must provide a doctype".to_string()
                } else {
                    format!("Premature end of file.{}", self.tag_stack_message())
                }
            }
            TokenKind::StartTag => format!(
                "Start tag '{}' isn't allowed here.{}",
                token_error_name(token),
                self.tag_stack_message()
            ),
            TokenKind::EndTag => format!(
                "End tag '{}' isn't allowed here.{}",
                token_error_name(token),
                self.tag_stack_message()
            ),
        }
    }

    fn acknowledge(&mut self) {
        self.ack = true;
    }

    fn frameset_not_ok(&mut self) {
        self.frameset_ok = false;
    }

    fn append_node(&self, parent: &NodeRef, node: &NodeRef) {
        node.0.borrow_mut().parent = Rc::downgrade(&parent.0);
        parent.0.borrow_mut().children.push(node.clone());
    }

    fn insert_at(&self, parent: &NodeRef, node: &NodeRef, index: Option<usize>) {
        node.0.borrow_mut().parent = Rc::downgrade(&parent.0);
        let mut parent_inner = parent.0.borrow_mut();
        match index {
            None => parent_inner.children.push(node.clone()),
            Some(index) if index <= parent_inner.children.len() => {
                parent_inner.children.insert(index, node.clone());
            }
            Some(_) => parent_inner.children.push(node.clone()),
        }
    }

    fn detach(&self, node: &NodeRef) {
        let parent_rc = node.0.borrow().parent.upgrade();
        let Some(parent_rc) = parent_rc else {
            return;
        };
        parent_rc
            .borrow_mut()
            .children
            .retain(|child| !child.same(node));
        node.0.borrow_mut().parent = Weak::new();
    }

    fn insertion_location(
        &self,
        override_node: Option<NodeRef>,
    ) -> (Option<NodeRef>, Option<usize>) {
        let target = if let Some(node) = override_node {
            node
        } else if self.root.is_some() {
            match self.current_node() {
                Some(node) => node,
                None => return (None, None),
            }
        } else {
            self.document.clone()
        };
        if !(self.foster && ns_in(&target, FOSTER_TARGETS)) {
            return (Some(target), None);
        }
        let mut last_template: Option<NodeRef> = None;
        let mut last_table: Option<NodeRef> = None;
        let mut template_at: isize = -1;
        let mut table_at: isize = -1;
        for (index, node) in self.open.iter().enumerate() {
            if html_is(node, "template") {
                last_template = Some(node.clone());
                template_at = index as isize;
            }
            if html_is(node, "table") {
                last_table = Some(node.clone());
                table_at = index as isize;
            }
        }
        if last_template.is_some() && (last_table.is_none() || template_at > table_at) {
            return (last_template, None);
        }
        let Some(table) = last_table else {
            return (self.open.first().cloned(), None);
        };
        let parent_rc = table.0.borrow().parent.upgrade();
        if let Some(parent_rc) = parent_rc {
            let parent = NodeRef(parent_rc);
            let index = parent
                .0
                .borrow()
                .children
                .iter()
                .position(|child| child.same(&table));
            return (Some(parent), index);
        }
        (self.open_at(table_at - 1), None)
    }

    fn open_at(&self, index: isize) -> Option<NodeRef> {
        let idx = ruby_index(self.open.len(), index)?;
        Some(self.open[idx].clone())
    }

    fn flush_text(&mut self) {
        if self.text.is_empty() {
            return;
        }
        let kind = if self.text_kind == TextKind::Cdata {
            NodeKind::Cdata
        } else {
            NodeKind::Text
        };
        let node = NodeRef::new(kind);
        {
            let mut inner = node.0.borrow_mut();
            inner.content = self.text.clone();
            inner.name = self.text.clone();
            inner.line = self.text_line.unwrap_or(0);
        }
        let (target, index) = self.insertion_location(None);
        if let Some(target) = target {
            let is_document = target.0.borrow().kind == NodeKind::Document;
            if !is_document {
                self.insert_at(&target, &node, index);
            }
        }
        self.text.clear();
        self.text_kind = TextKind::Whitespace;
        self.text_line = None;
    }

    fn insert_text(&mut self, token: &Token, replacement: bool) {
        if self.text.is_empty() {
            self.text_line = Some(token.line);
        }
        if replacement {
            self.text.push('\u{FFFD}');
        } else {
            self.text.push_str(text_of(token));
        }
        if token.kind == TokenKind::Character {
            self.text_kind = TextKind::Text;
        } else if token.kind == TokenKind::Cdata {
            self.text_kind = TextKind::Cdata;
        }
    }

    fn insert_element(&mut self, node: NodeRef) -> NodeRef {
        self.flush_text();
        let (target, index) = self.insertion_location(None);
        if let Some(target) = target {
            self.insert_at(&target, &node, index);
        }
        self.open.push(node.clone());
        node
    }

    fn insert_html(&mut self, token: &Token, name: Option<&str>) -> NodeRef {
        let source = name.unwrap_or(token.name.as_str());
        let key = ascii_lower(source);
        let tag = if known(&key) { key } else { source.to_string() };
        let node = make_element(&tag, Ns::Html, html_attrs(token), token.line);
        self.insert_element(node)
    }

    fn insert_implied(&mut self, name: &str) -> NodeRef {
        let line = self.current.as_ref().map(|token| token.line).unwrap_or(0);
        let node = make_element(name, Ns::Html, Vec::new(), line);
        self.insert_element(node)
    }

    fn insert_foreign(&mut self, token: &Token, namespace: Ns, adjust_tag: bool) -> NodeRef {
        let name = foreign_tag_name(token, namespace, adjust_tag);
        let node = make_element(
            &name,
            namespace,
            foreign_attrs(token, namespace),
            token.line,
        );
        let node = self.insert_element(node);
        if token.self_closing {
            self.pop_current_node();
            self.ack = true;
        }
        node
    }

    fn pop_current_node(&mut self) -> Option<NodeRef> {
        self.flush_text();
        self.open.pop()
    }

    /// Pop the named node, then stop. Do not pop one more node.
    fn pop_through_html(&mut self, name: &str) {
        loop {
            let node = self.pop_current_node();
            match node {
                None => break,
                Some(node) if html_is(&node, name) => break,
                Some(_) => {}
            }
        }
    }

    fn append_comment(&mut self, parent: &NodeRef, token: &Token) {
        self.flush_text();
        let node = NodeRef::new(NodeKind::Comment);
        let data = text_of(token).to_string();
        {
            let mut inner = node.0.borrow_mut();
            inner.content = data.clone();
            inner.name = data;
            inner.line = token.line;
        }
        self.append_node(parent, &node);
    }

    fn has_in_scope(&self, names: &[&str], scope: &[(Ns, &str)], negate: bool) -> bool {
        let mut index = self.open.len() as isize - 1;
        while index >= 0 {
            let node = self.open[index as usize].clone();
            index -= 1;
            if node.0.borrow().kind != NodeKind::Element {
                continue;
            }
            let matched = {
                let inner = node.0.borrow();
                inner.namespace == Ns::Html && names.iter().any(|name| eq_lower(&inner.name, name))
            };
            if matched {
                return true;
            }
            let found = ns_in(&node, scope);
            if negate != found {
                return false;
            }
        }
        false
    }

    fn has_scope(&self, name: &str) -> bool {
        self.has_in_scope(&[name], DEFAULT_SCOPE, false)
    }

    fn has_list_scope(&self, name: &str) -> bool {
        self.has_in_scope(&[name], LIST_SCOPE, false)
    }

    fn has_button_scope(&self, name: &str) -> bool {
        self.has_in_scope(&[name], BUTTON_SCOPE, false)
    }

    fn has_table_scope(&self, name: &str) -> bool {
        self.has_in_scope(&[name], TABLE_SCOPE, false)
    }

    fn has_select_scope(&self, name: &str) -> bool {
        self.has_in_scope(&[name], SELECT_SCOPE, true)
    }

    fn has_open(&self, name: &str) -> bool {
        self.has_in_scope(&[name], OPEN_SCOPE, false)
    }

    fn has_node_in_scope(&self, node: &NodeRef) -> bool {
        let mut index = self.open.len() as isize - 1;
        while index >= 0 {
            let current = self.open[index as usize].clone();
            index -= 1;
            if current.same(node) {
                return true;
            }
            if current.0.borrow().kind != NodeKind::Element {
                continue;
            }
            if ns_in(&current, DEFAULT_SCOPE) {
                return false;
            }
        }
        false
    }

    fn has_heading_in_scope(&self) -> bool {
        self.has_in_scope(HEADING, DEFAULT_SCOPE, false)
    }

    fn on_open_stack(&self, node: &NodeRef) -> bool {
        self.open.iter().any(|item| item.same(node))
    }

    fn generate_implied(&mut self, exception: Option<&str>) {
        loop {
            let Some(node) = self.current_node() else {
                break;
            };
            if !html_in_set(&node, IMPLIED) {
                break;
            }
            if let Some(exception) = exception {
                if html_is(&node, exception) {
                    break;
                }
            }
            self.pop_current_node();
        }
    }

    fn generate_implied_thoroughly(&mut self) {
        while self
            .current_node()
            .map(|node| html_in_set(&node, IMPLIED_THOROUGH))
            .unwrap_or(false)
        {
            self.pop_current_node();
        }
    }

    fn nonclosable_on_stack(&self) -> bool {
        self.open.iter().any(|node| !html_in_set(node, CLOSABLE))
    }

    fn current_matches(&self, namespace: Ns, key: &str) -> bool {
        let Some(node) = self.current_node() else {
            return false;
        };
        let inner = node.0.borrow();
        inner.namespace == namespace && eq_lower(&inner.name, key)
    }

    fn implicitly_close(&mut self, token: &Token, namespace: Ns, name: &str) {
        let key = ascii_lower(name);
        let exception = if namespace == Ns::Html {
            Some(key.as_str())
        } else {
            None
        };
        self.generate_implied(exception);
        if !self.current_matches(namespace, &key) {
            self.add_error(token);
            while !self.current_matches(namespace, &key) {
                if self.open.is_empty() {
                    break;
                }
                self.pop_current_node();
            }
        }
        self.pop_current_node();
    }

    fn close_p(&mut self, token: &Token) {
        if !self.has_button_scope("p") {
            return;
        }
        self.implicitly_close(token, Ns::Html, "p");
    }

    fn close_list(&mut self, token: &Token, is_li: bool) {
        self.frameset_not_ok();
        let mut index = self.open.len() as isize - 1;
        while index >= 0 {
            let node = self.open[index as usize].clone();
            index -= 1;
            let matched = if is_li {
                html_is(&node, "li")
            } else {
                html_in_set(&node, DD_DT)
            };
            if matched {
                let (namespace, name) = {
                    let inner = node.0.borrow();
                    (inner.namespace, inner.name.clone())
                };
                self.implicitly_close(token, namespace, &name);
                return;
            }
            if is_special(&node) && !html_in_set(&node, ADDRESS_DIV_P) {
                return;
            }
        }
    }

    fn close_table(&mut self) -> bool {
        if !self.has_table_scope("table") {
            return false;
        }
        let mut node = self.pop_current_node();
        while !node
            .as_ref()
            .map(|item| html_is(item, "table"))
            .unwrap_or(false)
        {
            node = self.pop_current_node();
            if node.is_none() {
                break;
            }
        }
        self.reset_mode();
        true
    }

    fn close_cell(&mut self, token: &Token, name: &str) {
        self.generate_implied(None);
        let ok = self
            .current_node()
            .map(|node| html_is(&node, name))
            .unwrap_or(false);
        if !ok {
            self.add_error(token);
        }
        let mut node: Option<NodeRef> = None;
        while !node
            .as_ref()
            .map(|item| html_is(item, name))
            .unwrap_or(false)
        {
            node = self.pop_current_node();
            if node.is_none() {
                break;
            }
        }
        self.clear_formatting();
        self.mode = Mode::InRow;
    }

    fn close_current_cell(&mut self, token: &Token) {
        let name = if self.has_table_scope("td") {
            "td"
        } else {
            "th"
        };
        self.close_cell(token, name);
    }

    fn close_select(&mut self) {
        let mut node = self.pop_current_node();
        while !node
            .as_ref()
            .map(|item| html_is(item, "select"))
            .unwrap_or(false)
        {
            node = self.pop_current_node();
            if node.is_none() {
                break;
            }
        }
        self.reset_mode();
    }

    fn clear_stack_to(&mut self, set: &[(Ns, &str)]) {
        while !self
            .current_node()
            .map(|node| ns_in(&node, set))
            .unwrap_or(false)
        {
            if self.open.is_empty() {
                break;
            }
            self.pop_current_node();
        }
    }

    fn clear_formatting(&mut self) {
        loop {
            match self.formatting.pop() {
                None | Some(FormEntry::Scope) => break,
                Some(FormEntry::Node(_)) => {}
            }
        }
    }

    fn add_formatting(&mut self, entry: FormEntry) {
        if let FormEntry::Node(node) = &entry {
            let node = node.clone();
            let mut earliest: Option<usize> = None;
            let mut count = 0usize;
            let mut index = self.formatting.len() as isize - 1;
            while index >= 0 {
                let other = self.formatting[index as usize].clone();
                if other.is_scope() {
                    break;
                }
                if let Some(other_node) = other.node() {
                    if same_formatting(other_node, &node) {
                        count += 1;
                        earliest = Some(index as usize);
                    }
                }
                index -= 1;
            }
            if count >= 3 {
                if let Some(at) = earliest {
                    self.formatting.remove(at);
                }
            }
        }
        self.formatting.push(entry);
    }

    fn reconstruct(&mut self) {
        if self.formatting.is_empty() {
            return;
        }
        let mut index = self.formatting.len() as isize - 1;
        if self.formatting_boundary(index) {
            return;
        }
        loop {
            if index == 0 {
                index = -1;
                break;
            }
            index -= 1;
            if self.formatting_boundary(index) {
                break;
            }
        }
        index += 1;
        while (index as usize) < self.formatting.len() {
            let Some(element) = self.formatting[index as usize].node().cloned() else {
                index += 1;
                continue;
            };
            let copy = clone_node(&element);
            let (target, at) = self.insertion_location(None);
            if let Some(target) = target {
                self.insert_at(&target, &copy, at);
            }
            self.open.push(copy.clone());
            self.formatting[index as usize] = FormEntry::Node(copy);
            index += 1;
        }
    }

    fn formatting_boundary(&self, index: isize) -> bool {
        match self.formatting[index as usize].clone() {
            FormEntry::Scope => true,
            FormEntry::Node(node) => self.on_open_stack(&node),
        }
    }

    fn merge_attrs(&self, token: &Token, node: &NodeRef) {
        for (name, value) in &token.attrs {
            let key = ascii_lower(name);
            let exists = node
                .0
                .borrow()
                .attrs
                .iter()
                .any(|(existing, _, _)| eq_lower(existing, &key));
            if exists {
                continue;
            }
            node.0
                .borrow_mut()
                .attrs
                .push((name.clone(), value.clone(), None));
        }
    }

    fn run_generic(&mut self, token: &Token, state: TokState) {
        self.insert_html(token, None);
        self.tokenizer.set_state(state);
        self.original_mode = self.mode;
        self.mode = Mode::Text;
    }

    fn any_other_end_tag(&mut self, token: &Token) {
        let name = ascii_lower(&token.name);
        let mut index = self.open.len() as isize - 1;
        while index >= 0 {
            let node = self.open[index as usize].clone();
            index -= 1;
            let matches = {
                let inner = node.0.borrow();
                inner.namespace == Ns::Html && eq_lower(&inner.name, &name)
            };
            if matches {
                self.generate_implied(Some(name.as_str()));
                let same = self
                    .current_node()
                    .map(|current| current.same(&node))
                    .unwrap_or(false);
                if !same {
                    self.add_error(token);
                }
                loop {
                    match self.pop_current_node() {
                        Some(popped) if popped.same(&node) => break,
                        None => break,
                        _ => {}
                    }
                }
                return;
            } else if is_special(&node) {
                self.add_error(token);
                return;
            }
        }
    }

    fn adoption_agency(&mut self, token: &Token) {
        let subject = ascii_lower(&token.name);
        let current_matches = self
            .current_node()
            .map(|node| html_is(&node, &subject))
            .unwrap_or(false);
        if current_matches {
            let current = self.current_node().unwrap();
            let listed = self.formatting.iter().any(|entry| {
                entry
                    .node()
                    .map(|node| node.same(&current))
                    .unwrap_or(false)
            });
            if !listed {
                self.pop_current_node();
                return;
            }
        }
        for _ in 0..8 {
            let mut formatting: Option<NodeRef> = None;
            let mut open_index: Option<usize> = None;
            let mut index = self.formatting.len() as isize - 1;
            while index >= 0 {
                let entry = self.formatting[index as usize].clone();
                if entry.is_scope() {
                    break;
                }
                if let Some(node) = entry.node() {
                    if html_is(node, &subject) {
                        let node = node.clone();
                        open_index = self.open.iter().position(|item| item.same(&node));
                        formatting = Some(node);
                        break;
                    }
                }
                index -= 1;
            }
            let Some(formatting) = formatting else {
                self.any_other_end_tag(token);
                return;
            };
            let Some(open_index) = open_index else {
                self.add_error(token);
                self.remove_formatting(&formatting);
                return;
            };
            if !self.has_scope(&subject) {
                self.add_error(token);
                return;
            }
            let is_current = self
                .current_node()
                .map(|node| node.same(&formatting))
                .unwrap_or(false);
            if !is_current {
                self.add_error(token);
            }
            let mut furthest: Option<NodeRef> = None;
            for at in open_index..self.open.len() {
                let node = self.open[at].clone();
                if is_special(&node) {
                    furthest = Some(node);
                    break;
                }
            }
            let Some(furthest) = furthest else {
                loop {
                    match self.pop_current_node() {
                        Some(popped) if popped.same(&formatting) => break,
                        None => break,
                        _ => {}
                    }
                }
                self.remove_formatting(&formatting);
                return;
            };
            let common = self.open_at(open_index as isize - 1);
            let mut bookmark = self.formatting_index(&formatting).unwrap_or(0) as isize + 1;
            let mut node = furthest.clone();
            let mut last = furthest.clone();
            let mut saved = self
                .open
                .iter()
                .position(|item| item.same(&node))
                .map(|at| at as isize)
                .unwrap_or(0);
            let mut inner = 0i32;
            loop {
                inner += 1;
                let found = self
                    .open
                    .iter()
                    .position(|item| item.same(&node))
                    .map(|at| at as isize);
                let mut node_index = found.unwrap_or(saved);
                saved = node_index - 1;
                node_index = saved;
                let Some(next) = self.open_at(node_index) else {
                    break;
                };
                node = next;
                if node.same(&formatting) {
                    break;
                }
                let fmt_index = self.formatting_index(&node);
                if inner > 3 {
                    if let Some(fmt_index) = fmt_index {
                        self.formatting.remove(fmt_index);
                        if (fmt_index as isize) < bookmark {
                            bookmark -= 1;
                        }
                        continue;
                    }
                }
                let Some(fmt_index) = fmt_index else {
                    delete_at(&mut self.open, node_index);
                    continue;
                };
                let clone = clone_node(&node);
                self.formatting[fmt_index] = FormEntry::Node(clone.clone());
                self.set_open(node_index, clone.clone());
                node = clone;
                if last.same(&furthest) {
                    bookmark = fmt_index as isize + 1;
                }
                self.detach(&last);
                self.append_node(&node, &last);
                last = node.clone();
            }
            self.detach(&last);
            let (target, at) = self.insertion_location(common);
            if let Some(target) = target {
                self.insert_at(&target, &last, at);
            }
            let created = clone_node(&formatting);
            {
                let moved = {
                    let mut created_inner = created.0.borrow_mut();
                    let mut furthest_inner = furthest.0.borrow_mut();
                    std::mem::swap(&mut created_inner.children, &mut furthest_inner.children);
                    created_inner.children.clone()
                };
                for child in moved {
                    child.0.borrow_mut().parent = Rc::downgrade(&created.0);
                }
            }
            self.append_node(&furthest, &created);
            if let Some(fmt_index) = self.formatting_index(&formatting) {
                if (fmt_index as isize) < bookmark {
                    bookmark -= 1;
                }
                self.formatting.remove(fmt_index);
            }
            insert_entry(
                &mut self.formatting,
                bookmark,
                FormEntry::Node(created.clone()),
            );
            self.open.retain(|item| !item.same(&formatting));
            if let Some(at) = self.open.iter().position(|item| item.same(&furthest)) {
                self.open.insert(at + 1, created);
            }
        }
    }

    fn formatting_index(&self, node: &NodeRef) -> Option<usize> {
        self.formatting
            .iter()
            .position(|entry| entry.node().map(|item| item.same(node)).unwrap_or(false))
    }

    fn remove_formatting(&mut self, node: &NodeRef) {
        self.formatting
            .retain(|entry| entry.node().map(|item| !item.same(node)).unwrap_or(true));
    }

    fn set_open(&mut self, index: isize, node: NodeRef) {
        if let Some(idx) = ruby_index(self.open.len(), index) {
            self.open[idx] = node;
        }
    }

    /// Ruby returns the index after it has already decremented it.
    fn find_anchor(&self) -> Option<isize> {
        let mut index = self.formatting.len() as isize - 1;
        while index >= 0 {
            let entry = self.formatting[index as usize].clone();
            index -= 1;
            if entry.is_scope() {
                return None;
            }
            if entry.node().map(|node| html_is(node, "a")).unwrap_or(false) {
                return Some(index);
            }
        }
        None
    }

    fn appropriate_mode(&self, index: usize) -> Mode {
        let mut node = self.open[index].clone();
        let last = index == 0;
        if last {
            if let Some(ctx) = &self.fragment_ctx {
                node = ctx.clone();
            }
        }
        let (namespace, name) = {
            let inner = node.0.borrow();
            (inner.namespace, ascii_lower(&inner.name))
        };
        if namespace != Ns::Html {
            return if last { Mode::InBody } else { Mode::Initial };
        }
        match name.as_str() {
            "select" => {
                if last {
                    return Mode::InSelect;
                }
                let mut ancestor_index = index as isize;
                while ancestor_index > 0 {
                    let ancestor = self.open[ancestor_index as usize].clone();
                    if html_is(&ancestor, "template") {
                        return Mode::InSelect;
                    }
                    if html_is(&ancestor, "table") {
                        return Mode::InSelectInTable;
                    }
                    ancestor_index -= 1;
                }
                Mode::InSelect
            }
            "td" | "th" => {
                if last {
                    Mode::InBody
                } else {
                    Mode::InCell
                }
            }
            "tr" => Mode::InRow,
            "tbody" | "thead" | "tfoot" => Mode::InTableBody,
            "caption" => Mode::InCaption,
            "colgroup" => Mode::InColumnGroup,
            "table" => Mode::InTable,
            "template" => self.template_modes.last().copied().unwrap_or(Mode::Initial),
            "head" => {
                if last {
                    Mode::InBody
                } else {
                    Mode::InHead
                }
            }
            "body" => Mode::InBody,
            "frameset" => Mode::InFrameset,
            "html" => {
                if self.head.is_some() {
                    Mode::AfterHead
                } else {
                    Mode::BeforeHead
                }
            }
            _ => {
                if last {
                    Mode::InBody
                } else {
                    Mode::Initial
                }
            }
        }
    }

    fn reset_mode(&mut self) {
        let mut index = self.open.len() as isize - 1;
        while index >= 0 {
            let mode = self.appropriate_mode(index as usize);
            if mode != Mode::Initial {
                self.mode = mode;
                return;
            }
            index -= 1;
        }
        self.mode = Mode::InBody;
    }

    fn finish_parsing(&mut self) {
        self.flush_text();
        while !self.open.is_empty() {
            self.pop_current_node();
        }
        let mut document = self.document.0.borrow_mut();
        document.doctype_name = document.doctype_name.clone();
        document.public_id = document.public_id.clone();
        document.system_id = document.system_id.clone();
    }

    fn handle_token(&mut self, token: &Token) {
        let node = self.adjusted_current();
        let html_content = match &node {
            None => true,
            Some(node) => {
                let namespace = node.0.borrow().namespace;
                let annotation_svg = {
                    let inner = node.0.borrow();
                    inner.namespace == Ns::MathMl
                        && eq_lower(&inner.name, "annotation-xml")
                        && tag_is(token, TokenKind::StartTag, "svg")
                };
                namespace == Ns::Html
                    || (mathml_ip(node) && mathml_integration_token(token))
                    || annotation_svg
                    || (html_ip(node) && html_integration_token(token))
                    || token.kind == TokenKind::Eof
            }
        };
        if html_content {
            self.handle_html(token);
        } else {
            self.handle_foreign(token);
        }
    }

    fn handle_html(&mut self, token: &Token) {
        match self.mode {
            Mode::Initial => self.handle_initial(token),
            Mode::BeforeHtml => self.handle_before_html(token),
            Mode::BeforeHead => self.handle_before_head(token),
            Mode::InHead => self.handle_in_head(token),
            Mode::InHeadNoscript => self.handle_in_head_noscript(token),
            Mode::AfterHead => self.handle_after_head(token),
            Mode::InBody => self.handle_in_body(token),
            Mode::Text => self.handle_text(token),
            Mode::InTable => self.handle_in_table(token),
            Mode::InTableText => self.handle_in_table_text(token),
            Mode::InCaption => self.handle_in_caption(token),
            Mode::InColumnGroup => self.handle_in_column_group(token),
            Mode::InTableBody => self.handle_in_table_body(token),
            Mode::InRow => self.handle_in_row(token),
            Mode::InCell => self.handle_in_cell(token),
            Mode::InSelect => self.handle_in_select(token),
            Mode::InSelectInTable => self.handle_in_select_in_table(token),
            Mode::InTemplate => self.handle_in_template(token),
            Mode::AfterBody => self.handle_after_body(token),
            Mode::InFrameset => self.handle_in_frameset(token),
            Mode::AfterFrameset => self.handle_after_frameset(token),
            Mode::AfterAfterBody => self.handle_after_after_body(token),
            Mode::AfterAfterFrameset => self.handle_after_after_frameset(token),
        }
    }

    fn handle_initial(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace {
            return;
        }
        if token.kind == TokenKind::Comment {
            self.append_comment(&self.document.clone(), token);
            return;
        }
        if token.kind == TokenKind::Doctype {
            let quirks_mode = doctype_quirks(token);
            {
                let mut document = self.document.0.borrow_mut();
                document.has_doctype = true;
                document.doctype_name = token.name.clone();
                document.public_id = token.public_id.clone();
                document.system_id = token.system_id.clone();
                document.quirks_mode = quirks_mode;
            }
            self.mode = Mode::BeforeHtml;
            if illegal_doctype(token) {
                self.add_error(token);
            }
            return;
        }
        self.add_error(token);
        self.document.0.borrow_mut().quirks_mode = quirks::QUIRKS;
        self.mode = Mode::BeforeHtml;
        self.reprocess = true;
    }

    fn handle_before_html(&mut self, token: &Token) {
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if token.kind == TokenKind::Comment {
            self.append_comment(&self.document.clone(), token);
            return;
        }
        if token.kind == TokenKind::Whitespace {
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            let node = self.insert_html(token, None);
            self.root = Some(node);
            self.mode = Mode::BeforeHead;
            return;
        }
        if token.kind == TokenKind::EndTag && !tags_in(token, TokenKind::EndTag, HEAD_BODY_HTML_BR)
        {
            self.add_error(token);
            return;
        }
        let node = self.insert_implied("html");
        self.root = Some(node);
        self.mode = Mode::BeforeHead;
        self.reprocess = true;
    }

    fn handle_before_head(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace {
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "head") {
            self.head = Some(self.insert_html(token, None));
            self.mode = Mode::InHead;
            return;
        }
        if token.kind == TokenKind::EndTag && !tags_in(token, TokenKind::EndTag, HEAD_BODY_HTML_BR)
        {
            self.add_error(token);
            return;
        }
        self.head = Some(self.insert_implied("head"));
        self.mode = Mode::InHead;
        self.reprocess = true;
    }

    fn handle_in_head(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace {
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tags_in(token, TokenKind::StartTag, BASE_LINK) {
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "meta") {
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "title") {
            self.run_generic(token, TokState::Rcdata);
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["noframes", "style"])
            || (tag_is(token, TokenKind::StartTag, "noscript") && self.noscript_as_text)
        {
            self.run_generic(token, TokState::Rawtext);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "noscript") {
            self.insert_html(token, None);
            self.mode = Mode::InHeadNoscript;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "script") {
            self.run_generic(token, TokState::ScriptData);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "head") {
            self.pop_current_node();
            self.mode = Mode::AfterHead;
            return;
        }
        if tags_in(token, TokenKind::EndTag, BODY_HTML_BR) {
            self.pop_current_node();
            self.mode = Mode::AfterHead;
            self.reprocess = true;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "template") {
            self.insert_html(token, None);
            self.add_formatting(FormEntry::Scope);
            self.frameset_not_ok();
            self.mode = Mode::InTemplate;
            self.template_modes.push(Mode::InTemplate);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "template") {
            if !self.has_open("template") {
                self.add_error(token);
                return;
            }
            self.generate_implied_thoroughly();
            let is_template = self
                .current_node()
                .map(|node| html_is(&node, "template"))
                .unwrap_or(false);
            if !is_template {
                self.add_error(token);
            }
            self.pop_through_html("template");
            self.clear_formatting();
            self.template_modes.pop();
            self.reset_mode();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "head") || token.kind == TokenKind::EndTag {
            self.add_error(token);
            return;
        }
        self.pop_current_node();
        self.mode = Mode::AfterHead;
        self.reprocess = true;
    }

    fn handle_in_head_noscript(&mut self, token: &Token) {
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "noscript") {
            self.pop_current_node();
            self.mode = Mode::InHead;
            return;
        }
        if token.kind == TokenKind::Whitespace
            || token.kind == TokenKind::Comment
            || tags_in(
                token,
                TokenKind::StartTag,
                &["basefont", "bgsound", "link", "meta", "noframes", "style"],
            )
        {
            self.handle_in_head(token);
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["head", "noscript"])
            || (token.kind == TokenKind::EndTag && !tag_is(token, TokenKind::EndTag, "br"))
        {
            self.add_error(token);
            return;
        }
        self.add_error(token);
        self.pop_current_node();
        self.mode = Mode::InHead;
        self.reprocess = true;
    }

    fn handle_after_head(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace {
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "body") {
            self.insert_html(token, None);
            self.frameset_not_ok();
            self.mode = Mode::InBody;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "frameset") {
            self.insert_html(token, None);
            self.mode = Mode::InFrameset;
            return;
        }
        if tags_in(token, TokenKind::StartTag, HEAD_ELS) {
            self.add_error(token);
            self.flush_text();
            if let Some(head) = self.head.clone() {
                self.open.push(head.clone());
                self.handle_in_head(token);
                self.open.retain(|node| !node.same(&head));
            } else {
                self.handle_in_head(token);
            }
            return;
        }
        if tag_is(token, TokenKind::EndTag, "template") {
            self.handle_in_head(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "head")
            || (token.kind == TokenKind::EndTag && !tags_in(token, TokenKind::EndTag, BODY_HTML_BR))
        {
            self.add_error(token);
            return;
        }
        self.insert_implied("body");
        self.mode = Mode::InBody;
        self.reprocess = true;
    }

    fn handle_in_body(&mut self, token: &Token) {
        if token.kind == TokenKind::Null {
            self.add_error(token);
            return;
        }
        if token.kind == TokenKind::Whitespace {
            self.reconstruct();
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Character || token.kind == TokenKind::Cdata {
            self.reconstruct();
            self.insert_text(token, false);
            self.frameset_not_ok();
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.add_error(token);
            if self.has_open("template") {
                return;
            }
            if let Some(root) = self.root.clone() {
                self.merge_attrs(token, &root);
            }
            return;
        }
        if tags_in(token, TokenKind::StartTag, HEAD_ELS)
            || tag_is(token, TokenKind::EndTag, "template")
        {
            self.handle_in_head(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "body") {
            self.add_error(token);
            let second_is_body = self
                .open
                .get(1)
                .map(|node| html_is(node, "body"))
                .unwrap_or(false);
            if self.open.len() < 2 || !second_is_body || self.has_open("template") {
                return;
            }
            self.frameset_not_ok();
            let body = self.open[1].clone();
            self.merge_attrs(token, &body);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "frameset") {
            self.add_error(token);
            let second_is_body = self
                .open
                .get(1)
                .map(|node| html_is(node, "body"))
                .unwrap_or(false);
            if self.open.len() < 2 || !second_is_body || !self.frameset_ok {
                return;
            }
            let body = self.open[1].clone();
            let mut popped: Option<NodeRef> = None;
            while !popped
                .as_ref()
                .map(|node| node.same(&body))
                .unwrap_or(false)
            {
                popped = self.pop_current_node();
                if popped.is_none() {
                    break;
                }
            }
            self.clear_formatting();
            self.detach(&body);
            self.insert_html(token, None);
            self.mode = Mode::InFrameset;
            return;
        }
        if token.kind == TokenKind::Eof {
            if !self.template_modes.is_empty() {
                self.handle_in_template(token);
                return;
            }
            if self.nonclosable_on_stack() {
                self.add_error(token);
            }
            return;
        }
        if tag_is(token, TokenKind::EndTag, "body") {
            if !self.has_scope("body") {
                self.add_error(token);
                return;
            }
            if self.nonclosable_on_stack() {
                self.add_error(token);
            }
            self.mode = Mode::AfterBody;
            return;
        }
        if tag_is(token, TokenKind::EndTag, "html") {
            if !self.has_scope("body") {
                self.add_error(token);
                return;
            }
            if self.nonclosable_on_stack() {
                self.add_error(token);
            }
            self.mode = Mode::AfterBody;
            self.reprocess = true;
            return;
        }
        if tags_in(token, TokenKind::StartTag, BLOCK_START) {
            self.close_p(token);
            self.insert_html(token, None);
            return;
        }
        if tags_in(token, TokenKind::StartTag, HEADING) {
            self.close_p(token);
            let in_heading = self
                .current_node()
                .map(|node| html_in_set(&node, HEADING))
                .unwrap_or(false);
            if in_heading {
                self.add_error(token);
                self.pop_current_node();
            }
            self.insert_html(token, None);
            return;
        }
        if tags_in(token, TokenKind::StartTag, PRE_LISTING) {
            self.close_p(token);
            self.insert_html(token, None);
            self.ignore_lf = true;
            self.frameset_not_ok();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "form") {
            if self.form.is_some() && !self.has_open("template") {
                self.add_error(token);
                return;
            }
            self.close_p(token);
            let form = self.insert_html(token, None);
            if !self.has_open("template") {
                self.form = Some(form);
            }
            return;
        }
        if tag_is(token, TokenKind::StartTag, "li") {
            self.close_list(token, true);
            self.close_p(token);
            self.insert_html(token, None);
            return;
        }
        if tags_in(token, TokenKind::StartTag, DD_DT) {
            self.close_list(token, false);
            self.close_p(token);
            self.insert_html(token, None);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "plaintext") {
            self.close_p(token);
            self.insert_html(token, None);
            self.tokenizer.set_state(TokState::Plaintext);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "button") {
            if self.has_scope("button") {
                self.add_error(token);
                self.generate_implied(None);
                self.pop_through_html("button");
            }
            self.reconstruct();
            self.insert_html(token, None);
            self.frameset_not_ok();
            return;
        }
        if tags_in(token, TokenKind::EndTag, BLOCK_END) {
            let name = ascii_lower(&token.name);
            if !self.has_scope(&name) {
                self.add_error(token);
                return;
            }
            self.implicitly_close(token, Ns::Html, &name);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "form") {
            if self.has_open("template") {
                if !self.has_scope("form") {
                    self.add_error(token);
                    return;
                }
                self.generate_implied(None);
                let is_form = self
                    .current_node()
                    .map(|node| html_is(&node, "form"))
                    .unwrap_or(false);
                if !is_form {
                    self.add_error(token);
                }
                self.pop_through_html("form");
                return;
            }
            let node = self.form.clone();
            self.form = None;
            let Some(node) = node else {
                self.add_error(token);
                return;
            };
            if !self.has_node_in_scope(&node) {
                self.add_error(token);
                return;
            }
            self.flush_text();
            self.generate_implied(None);
            let same = self
                .current_node()
                .map(|current| current.same(&node))
                .unwrap_or(false);
            if !same {
                self.add_error(token);
            }
            self.open.retain(|item| !item.same(&node));
            return;
        }
        if tag_is(token, TokenKind::EndTag, "p") {
            if !self.has_button_scope("p") {
                self.add_error(token);
                self.insert_implied("p");
            }
            self.implicitly_close(token, Ns::Html, "p");
            return;
        }
        if tag_is(token, TokenKind::EndTag, "li") {
            if !self.has_list_scope("li") {
                self.add_error(token);
                return;
            }
            self.implicitly_close(token, Ns::Html, "li");
            return;
        }
        if tags_in(token, TokenKind::EndTag, DD_DT) {
            let name = ascii_lower(&token.name);
            if !self.has_scope(&name) {
                self.add_error(token);
                return;
            }
            self.implicitly_close(token, Ns::Html, &name);
            return;
        }
        if tags_in(token, TokenKind::EndTag, HEADING) {
            if !self.has_heading_in_scope() {
                self.add_error(token);
                return;
            }
            self.generate_implied(None);
            let wanted = ascii_lower(&token.name);
            let matches = self
                .current_node()
                .map(|node| html_is(&node, &wanted))
                .unwrap_or(false);
            if !matches {
                self.add_error(token);
            }
            let mut node: Option<NodeRef> = None;
            while !node
                .as_ref()
                .map(|item| html_in_set(item, HEADING))
                .unwrap_or(false)
            {
                node = self.pop_current_node();
                if node.is_none() {
                    break;
                }
            }
            return;
        }
        if tag_is(token, TokenKind::StartTag, "a") {
            if self.find_anchor().is_some() {
                self.add_error(token);
                self.adoption_agency(token);
                if let Some(again) = self.find_anchor() {
                    if let Some(removed) = delete_at(&mut self.formatting, again) {
                        if let Some(removed_node) = removed.node().cloned() {
                            self.open.retain(|item| !item.same(&removed_node));
                        }
                    }
                }
            }
            self.reconstruct();
            let node = self.insert_html(token, None);
            self.add_formatting(FormEntry::Node(node));
            return;
        }
        if tags_in(token, TokenKind::StartTag, FORMAT_START) {
            self.reconstruct();
            let node = self.insert_html(token, None);
            self.add_formatting(FormEntry::Node(node));
            return;
        }
        if tag_is(token, TokenKind::StartTag, "nobr") {
            self.reconstruct();
            if self.has_scope("nobr") {
                self.add_error(token);
                self.adoption_agency(token);
                self.reconstruct();
            }
            self.insert_html(token, None);
            if let Some(current) = self.current_node() {
                self.add_formatting(FormEntry::Node(current));
            }
            return;
        }
        if tags_in(token, TokenKind::EndTag, FORMAT_END) {
            self.adoption_agency(token);
            return;
        }
        if tags_in(token, TokenKind::StartTag, APPLET_MARQUEE_OBJECT) {
            self.reconstruct();
            self.insert_html(token, None);
            self.add_formatting(FormEntry::Scope);
            self.frameset_not_ok();
            return;
        }
        if tags_in(token, TokenKind::EndTag, APPLET_MARQUEE_OBJECT) {
            let name = ascii_lower(&token.name);
            if !self.has_scope(&name) {
                self.add_error(token);
                return;
            }
            self.implicitly_close(token, Ns::Html, &name);
            self.clear_formatting();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "table") {
            let quirks_mode = self.document.0.borrow().quirks_mode;
            if quirks_mode != quirks::QUIRKS {
                self.close_p(token);
            }
            self.insert_html(token, None);
            self.frameset_not_ok();
            self.mode = Mode::InTable;
            return;
        }
        if tag_is(token, TokenKind::EndTag, "br") {
            self.add_error(token);
            self.reconstruct();
            self.insert_implied("br");
            self.pop_current_node();
            self.acknowledge();
            self.frameset_not_ok();
            return;
        }
        if tags_in(token, TokenKind::StartTag, VOID_BODY) {
            let image = tag_is(token, TokenKind::StartTag, "image");
            if image {
                self.add_error(token);
            }
            self.reconstruct();
            if image {
                self.insert_html(token, Some("img"));
            } else {
                self.insert_html(token, None);
            }
            self.pop_current_node();
            self.acknowledge();
            self.frameset_not_ok();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "input") {
            self.reconstruct();
            let node = self.insert_html(token, None);
            let hidden = {
                let inner = node.0.borrow();
                triple_attr_is(&inner.attrs, "type", "hidden")
            };
            self.pop_current_node();
            self.acknowledge();
            if !hidden {
                self.frameset_not_ok();
            }
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["param", "source", "track"]) {
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "hr") {
            self.close_p(token);
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            self.frameset_not_ok();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "textarea") {
            self.run_generic(token, TokState::Rcdata);
            self.ignore_lf = true;
            self.frameset_not_ok();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "xmp") {
            self.close_p(token);
            self.reconstruct();
            self.frameset_not_ok();
            self.run_generic(token, TokState::Rawtext);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "iframe") {
            self.frameset_not_ok();
            self.run_generic(token, TokState::Rawtext);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "noembed")
            || (tag_is(token, TokenKind::StartTag, "noscript") && self.noscript_as_text)
        {
            self.run_generic(token, TokState::Rawtext);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "select") {
            self.reconstruct();
            self.insert_html(token, None);
            self.frameset_not_ok();
            self.mode = if matches!(
                self.mode,
                Mode::InTable | Mode::InCaption | Mode::InTableBody | Mode::InRow | Mode::InCell
            ) {
                Mode::InSelectInTable
            } else {
                Mode::InSelect
            };
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["optgroup", "option"]) {
            if self
                .current_node()
                .map(|node| html_is(&node, "option"))
                .unwrap_or(false)
            {
                self.pop_current_node();
            }
            self.reconstruct();
            self.insert_html(token, None);
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["rb", "rtc"]) {
            if self.has_scope("ruby") {
                self.generate_implied(None);
                let is_ruby = self
                    .current_node()
                    .map(|node| html_is(&node, "ruby"))
                    .unwrap_or(false);
                if !is_ruby {
                    self.add_error(token);
                }
            }
            self.insert_html(token, None);
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["rp", "rt"]) {
            if self.has_scope("ruby") {
                self.generate_implied(Some("rtc"));
                let ok = self
                    .current_node()
                    .map(|node| html_is(&node, "ruby") || html_is(&node, "rtc"))
                    .unwrap_or(false);
                if !ok {
                    self.add_error(token);
                }
            }
            self.insert_html(token, None);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "math") {
            self.reconstruct();
            self.insert_foreign(token, Ns::MathMl, false);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "svg") {
            self.reconstruct();
            self.insert_foreign(token, Ns::Svg, false);
            return;
        }
        if tags_in(
            token,
            TokenKind::StartTag,
            &[
                "caption", "col", "colgroup", "frame", "head", "tbody", "td", "tfoot", "th",
                "thead", "tr",
            ],
        ) {
            self.add_error(token);
            return;
        }
        if token.kind == TokenKind::StartTag {
            self.reconstruct();
            self.insert_html(token, None);
            return;
        }
        self.any_other_end_tag(token);
    }

    fn handle_text(&mut self, token: &Token) {
        if token.kind == TokenKind::Character || token.kind == TokenKind::Whitespace {
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Eof {
            self.add_error(token);
            self.reprocess = true;
        }
        self.pop_current_node();
        self.mode = self.original_mode;
    }

    fn handle_in_table(&mut self, token: &Token) {
        if matches!(
            token.kind,
            TokenKind::Character | TokenKind::Whitespace | TokenKind::Null
        ) && self
            .current_node()
            .map(|node| ns_in(&node, TABLE_TEXT_NODES))
            .unwrap_or(false)
        {
            self.original_mode = self.mode;
            self.reprocess = true;
            self.mode = Mode::InTableText;
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "caption") {
            self.clear_stack_to(TABLE_CONTEXT);
            self.add_formatting(FormEntry::Scope);
            self.insert_html(token, None);
            self.mode = Mode::InCaption;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "colgroup") {
            self.clear_stack_to(TABLE_CONTEXT);
            self.insert_html(token, None);
            self.mode = Mode::InColumnGroup;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "col") {
            self.clear_stack_to(TABLE_CONTEXT);
            self.insert_implied("colgroup");
            self.reprocess = true;
            self.mode = Mode::InColumnGroup;
            return;
        }
        if tags_in(token, TokenKind::StartTag, TBODY_GROUP) {
            self.clear_stack_to(TABLE_CONTEXT);
            self.insert_html(token, None);
            self.mode = Mode::InTableBody;
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["td", "th", "tr"]) {
            self.clear_stack_to(TABLE_CONTEXT);
            self.insert_implied("tbody");
            self.mode = Mode::InTableBody;
            self.reprocess = true;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "table") {
            self.add_error(token);
            if self.close_table() {
                self.reprocess = true;
            }
            return;
        }
        if tag_is(token, TokenKind::EndTag, "table") {
            if !self.close_table() {
                self.add_error(token);
            }
            return;
        }
        if tags_in(token, TokenKind::EndTag, TABLE_END_BANS) {
            self.add_error(token);
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["style", "script", "template"])
            || tag_is(token, TokenKind::EndTag, "template")
        {
            self.handle_in_head(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "input")
            && pair_attr_is(&token.attrs, "type", "hidden")
        {
            self.add_error(token);
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "form") {
            self.add_error(token);
            if self.form.is_some() || self.has_open("template") {
                return;
            }
            self.form = Some(self.insert_html(token, None));
            self.pop_current_node();
            return;
        }
        if token.kind == TokenKind::Eof {
            self.handle_in_body(token);
            return;
        }
        self.add_error(token);
        self.foster = true;
        self.handle_in_body(token);
        self.foster = false;
    }

    fn handle_in_table_text(&mut self, token: &Token) {
        if token.kind == TokenKind::Null {
            self.add_error(token);
            return;
        }
        if token.kind == TokenKind::Whitespace || token.kind == TokenKind::Character {
            self.insert_text(token, false);
            self.table_tokens.push(token.clone());
            return;
        }
        if self.text_kind != TextKind::Whitespace {
            let pending = self.table_tokens.clone();
            for item in &pending {
                self.add_error(item);
            }
            self.foster = true;
            self.frameset_not_ok();
            self.reconstruct();
        }
        self.flush_text();
        self.table_tokens.clear();
        self.foster = false;
        self.reprocess = true;
        self.mode = self.original_mode;
    }

    fn handle_in_caption(&mut self, token: &Token) {
        let end_caption = tag_is(token, TokenKind::EndTag, "caption");
        let cell_or_table = tags_in(token, TokenKind::StartTag, CELL_START_CLOSE)
            || tag_is(token, TokenKind::EndTag, "table");
        if end_caption || cell_or_table {
            if !self.has_table_scope("caption") {
                self.add_error(token);
                return;
            }
            self.generate_implied(None);
            let is_caption = self
                .current_node()
                .map(|node| html_is(&node, "caption"))
                .unwrap_or(false);
            if !is_caption {
                self.add_error(token);
            }
            self.pop_through_html("caption");
            self.clear_formatting();
            self.mode = Mode::InTable;
            if !end_caption {
                self.reprocess = true;
            }
            return;
        }
        if tags_in(
            token,
            TokenKind::EndTag,
            &[
                "body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr",
            ],
        ) {
            self.add_error(token);
            return;
        }
        self.handle_in_body(token);
    }

    fn handle_in_column_group(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace {
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "col") {
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            return;
        }
        if tag_is(token, TokenKind::EndTag, "colgroup") {
            if !self
                .current_node()
                .map(|node| html_is(&node, "colgroup"))
                .unwrap_or(false)
            {
                self.add_error(token);
                return;
            }
            self.pop_current_node();
            self.mode = Mode::InTable;
            return;
        }
        if tag_is(token, TokenKind::EndTag, "col") {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "template")
            || tag_is(token, TokenKind::EndTag, "template")
        {
            self.handle_in_head(token);
            return;
        }
        if token.kind == TokenKind::Eof {
            self.handle_in_body(token);
            return;
        }
        if !self
            .current_node()
            .map(|node| html_is(&node, "colgroup"))
            .unwrap_or(false)
        {
            self.add_error(token);
            return;
        }
        self.pop_current_node();
        self.mode = Mode::InTable;
        self.reprocess = true;
    }

    fn handle_in_table_body(&mut self, token: &Token) {
        if tag_is(token, TokenKind::StartTag, "tr") {
            self.clear_stack_to(TABLE_BODY_CONTEXT);
            self.insert_html(token, None);
            self.mode = Mode::InRow;
            return;
        }
        if tags_in(token, TokenKind::StartTag, TD_TH) {
            self.add_error(token);
            self.clear_stack_to(TABLE_BODY_CONTEXT);
            self.insert_implied("tr");
            self.mode = Mode::InRow;
            self.reprocess = true;
            return;
        }
        if tags_in(token, TokenKind::EndTag, TBODY_GROUP) {
            let name = ascii_lower(&token.name);
            if !self.has_table_scope(&name) {
                self.add_error(token);
                return;
            }
            self.clear_stack_to(TABLE_BODY_CONTEXT);
            self.pop_current_node();
            self.mode = Mode::InTable;
            return;
        }
        if tags_in(
            token,
            TokenKind::StartTag,
            &["caption", "col", "colgroup", "tbody", "tfoot", "thead"],
        ) || tag_is(token, TokenKind::EndTag, "table")
        {
            if !(self.has_table_scope("tbody")
                || self.has_table_scope("thead")
                || self.has_table_scope("tfoot"))
            {
                self.add_error(token);
                return;
            }
            self.clear_stack_to(TABLE_BODY_CONTEXT);
            self.pop_current_node();
            self.mode = Mode::InTable;
            self.reprocess = true;
            return;
        }
        if tags_in(
            token,
            TokenKind::EndTag,
            &[
                "body", "caption", "col", "colgroup", "html", "td", "th", "tr",
            ],
        ) {
            self.add_error(token);
            return;
        }
        self.handle_in_table(token);
    }

    fn handle_in_row(&mut self, token: &Token) {
        if tags_in(token, TokenKind::StartTag, TD_TH) {
            self.clear_stack_to(TABLE_ROW_CONTEXT);
            self.insert_html(token, None);
            self.mode = Mode::InCell;
            self.add_formatting(FormEntry::Scope);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "tr") {
            if !self.has_table_scope("tr") {
                self.add_error(token);
                return;
            }
            self.clear_stack_to(TABLE_ROW_CONTEXT);
            self.pop_current_node();
            self.mode = Mode::InTableBody;
            return;
        }
        if tags_in(
            token,
            TokenKind::StartTag,
            &[
                "caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr",
            ],
        ) || tag_is(token, TokenKind::EndTag, "table")
        {
            if !self.has_table_scope("tr") {
                self.add_error(token);
                return;
            }
            self.clear_stack_to(TABLE_ROW_CONTEXT);
            self.pop_current_node();
            self.mode = Mode::InTableBody;
            self.reprocess = true;
            return;
        }
        if tags_in(token, TokenKind::EndTag, TBODY_GROUP) {
            let name = ascii_lower(&token.name);
            if !self.has_table_scope(&name) {
                self.add_error(token);
                return;
            }
            if !self.has_table_scope("tr") {
                return;
            }
            self.clear_stack_to(TABLE_ROW_CONTEXT);
            self.pop_current_node();
            self.mode = Mode::InTableBody;
            self.reprocess = true;
            return;
        }
        if tags_in(
            token,
            TokenKind::EndTag,
            &["body", "caption", "col", "colgroup", "html", "td", "th"],
        ) {
            self.add_error(token);
            return;
        }
        self.handle_in_table(token);
    }

    fn handle_in_cell(&mut self, token: &Token) {
        if tags_in(token, TokenKind::EndTag, TD_TH) {
            let name = ascii_lower(&token.name);
            if !self.has_table_scope(&name) {
                self.add_error(token);
                return;
            }
            self.close_cell(token, &name);
            return;
        }
        if tags_in(token, TokenKind::StartTag, CELL_START_CLOSE) {
            if !(self.has_table_scope("td") || self.has_table_scope("th")) {
                self.add_error(token);
                return;
            }
            self.reprocess = true;
            self.close_current_cell(token);
            return;
        }
        if tags_in(
            token,
            TokenKind::EndTag,
            &["body", "caption", "col", "colgroup", "html"],
        ) {
            self.add_error(token);
            return;
        }
        if tags_in(
            token,
            TokenKind::EndTag,
            &["table", "tbody", "tfoot", "thead", "tr"],
        ) {
            let name = ascii_lower(&token.name);
            if !self.has_table_scope(&name) {
                self.add_error(token);
                return;
            }
            self.reprocess = true;
            self.close_current_cell(token);
            return;
        }
        self.handle_in_body(token);
    }

    fn handle_in_select(&mut self, token: &Token) {
        if token.kind == TokenKind::Null {
            self.add_error(token);
            return;
        }
        if token.kind == TokenKind::Character || token.kind == TokenKind::Whitespace {
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "option") {
            if self
                .current_node()
                .map(|node| html_is(&node, "option"))
                .unwrap_or(false)
            {
                self.pop_current_node();
            }
            self.insert_html(token, None);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "optgroup") {
            if self
                .current_node()
                .map(|node| html_is(&node, "option"))
                .unwrap_or(false)
            {
                self.pop_current_node();
            }
            if self
                .current_node()
                .map(|node| html_is(&node, "optgroup"))
                .unwrap_or(false)
            {
                self.pop_current_node();
            }
            self.insert_html(token, None);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "hr") {
            if self
                .current_node()
                .map(|node| html_is(&node, "option"))
                .unwrap_or(false)
            {
                self.pop_current_node();
            }
            if self
                .current_node()
                .map(|node| html_is(&node, "optgroup"))
                .unwrap_or(false)
            {
                self.pop_current_node();
            }
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            return;
        }
        if tag_is(token, TokenKind::EndTag, "optgroup") {
            let option_in_group = self
                .current_node()
                .map(|node| html_is(&node, "option"))
                .unwrap_or(false)
                && self.open.len() >= 2
                && html_is(&self.open[self.open.len() - 2], "optgroup");
            if option_in_group {
                self.pop_current_node();
            }
            if self
                .current_node()
                .map(|node| html_is(&node, "optgroup"))
                .unwrap_or(false)
            {
                self.pop_current_node();
                return;
            }
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "option") {
            if self
                .current_node()
                .map(|node| html_is(&node, "option"))
                .unwrap_or(false)
            {
                self.pop_current_node();
                return;
            }
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "select") {
            if !self.has_select_scope("select") {
                self.add_error(token);
                return;
            }
            self.close_select();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "select") {
            self.add_error(token);
            if self.has_select_scope("select") {
                self.close_select();
            }
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["input", "keygen", "textarea"]) {
            self.add_error(token);
            if !self.has_select_scope("select") {
                return;
            }
            self.close_select();
            self.reprocess = true;
            return;
        }
        if tags_in(token, TokenKind::StartTag, &["script", "template"])
            || tag_is(token, TokenKind::EndTag, "template")
        {
            self.handle_in_head(token);
            return;
        }
        if token.kind == TokenKind::Eof {
            self.handle_in_body(token);
            return;
        }
        self.add_error(token);
    }

    fn handle_in_select_in_table(&mut self, token: &Token) {
        if tags_in(token, TokenKind::StartTag, SELECT_TABLE) {
            self.add_error(token);
            self.close_select();
            self.reprocess = true;
            return;
        }
        if tags_in(token, TokenKind::EndTag, SELECT_TABLE) {
            self.add_error(token);
            let name = ascii_lower(&token.name);
            if !self.has_table_scope(&name) {
                return;
            }
            self.close_select();
            self.reprocess = true;
            return;
        }
        self.handle_in_select(token);
    }

    fn handle_in_template(&mut self, token: &Token) {
        match token.kind {
            TokenKind::Whitespace
            | TokenKind::Character
            | TokenKind::Comment
            | TokenKind::Null
            | TokenKind::Doctype => {
                self.handle_in_body(token);
                return;
            }
            _ => {}
        }
        if tags_in(token, TokenKind::StartTag, HEAD_ELS)
            || tag_is(token, TokenKind::EndTag, "template")
        {
            self.handle_in_head(token);
            return;
        }
        if tags_in(
            token,
            TokenKind::StartTag,
            &["caption", "colgroup", "tbody", "tfoot", "thead"],
        ) {
            self.template_modes.pop();
            self.template_modes.push(Mode::InTable);
            self.mode = Mode::InTable;
            self.reprocess = true;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "col") {
            self.template_modes.pop();
            self.template_modes.push(Mode::InColumnGroup);
            self.mode = Mode::InColumnGroup;
            self.reprocess = true;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "tr") {
            self.template_modes.pop();
            self.template_modes.push(Mode::InTableBody);
            self.mode = Mode::InTableBody;
            self.reprocess = true;
            return;
        }
        if tags_in(token, TokenKind::StartTag, TD_TH) {
            self.template_modes.pop();
            self.template_modes.push(Mode::InRow);
            self.mode = Mode::InRow;
            self.reprocess = true;
            return;
        }
        if token.kind == TokenKind::StartTag {
            self.template_modes.pop();
            self.template_modes.push(Mode::InBody);
            self.mode = Mode::InBody;
            self.reprocess = true;
            return;
        }
        if token.kind == TokenKind::EndTag {
            self.add_error(token);
            return;
        }
        if token.kind != TokenKind::Eof {
            return;
        }
        if !self.has_open("template") {
            return;
        }
        self.add_error(token);
        self.pop_through_html("template");
        self.clear_formatting();
        self.template_modes.pop();
        self.reset_mode();
        self.reprocess = true;
    }

    fn handle_after_body(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace || tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(root) = self.root.clone() {
                self.append_comment(&root, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "html") {
            if self.fragment_ctx.is_some() {
                self.add_error(token);
                return;
            }
            self.mode = Mode::AfterAfterBody;
            return;
        }
        if token.kind == TokenKind::Eof {
            return;
        }
        self.add_error(token);
        self.mode = Mode::InBody;
        self.reprocess = true;
    }

    fn handle_in_frameset(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace {
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "frameset") {
            self.insert_html(token, None);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "frameset") {
            if self
                .current_node()
                .map(|node| html_is(&node, "html"))
                .unwrap_or(false)
            {
                self.add_error(token);
                return;
            }
            self.pop_current_node();
            let frameset = self
                .current_node()
                .map(|node| html_is(&node, "frameset"))
                .unwrap_or(false);
            if self.fragment_ctx.is_none() && !frameset {
                self.mode = Mode::AfterFrameset;
            }
            return;
        }
        if tag_is(token, TokenKind::StartTag, "frame") {
            self.insert_html(token, None);
            self.pop_current_node();
            self.acknowledge();
            return;
        }
        if tag_is(token, TokenKind::StartTag, "noframes") {
            self.handle_in_head(token);
            return;
        }
        if token.kind == TokenKind::Eof {
            if !self
                .current_node()
                .map(|node| html_is(&node, "html"))
                .unwrap_or(false)
            {
                self.add_error(token);
            }
            return;
        }
        self.add_error(token);
    }

    fn handle_after_frameset(&mut self, token: &Token) {
        if token.kind == TokenKind::Whitespace {
            self.insert_text(token, false);
            return;
        }
        if token.kind == TokenKind::Comment {
            if let Some(parent) = self.current_node() {
                self.append_comment(&parent, token);
            }
            return;
        }
        if token.kind == TokenKind::Doctype {
            self.add_error(token);
            return;
        }
        if tag_is(token, TokenKind::StartTag, "html") {
            self.handle_in_body(token);
            return;
        }
        if tag_is(token, TokenKind::EndTag, "html") {
            self.mode = Mode::AfterAfterFrameset;
            return;
        }
        if tag_is(token, TokenKind::StartTag, "noframes") {
            self.handle_in_head(token);
            return;
        }
        if token.kind == TokenKind::Eof {
            return;
        }
        self.add_error(token);
    }

    fn handle_after_after_body(&mut self, token: &Token) {
        if token.kind == TokenKind::Comment {
            self.append_comment(&self.document.clone(), token);
            return;
        }
        if token.kind == TokenKind::Doctype
            || token.kind == TokenKind::Whitespace
            || tag_is(token, TokenKind::StartTag, "html")
        {
            self.handle_in_body(token);
            return;
        }
        if token.kind == TokenKind::Eof {
            return;
        }
        self.add_error(token);
        self.mode = Mode::InBody;
        self.reprocess = true;
    }

    fn handle_after_after_frameset(&mut self, token: &Token) {
        if token.kind == TokenKind::Comment {
            self.append_comment(&self.document.clone(), token);
            return;
        }
        if token.kind == TokenKind::Doctype
            || token.kind == TokenKind::Whitespace
            || tag_is(token, TokenKind::StartTag, "html")
        {
            self.handle_in_body(token);
            return;
        }
        if token.kind == TokenKind::Eof {
            return;
        }
        if tag_is(token, TokenKind::StartTag, "noframes") {
            self.handle_in_head(token);
            return;
        }
        self.add_error(token);
    }

    fn handle_foreign(&mut self, token: &Token) {
        match token.kind {
            TokenKind::Null => {
                self.add_error(token);
                self.insert_text(token, true);
                return;
            }
            TokenKind::Whitespace => {
                self.insert_text(token, false);
                return;
            }
            TokenKind::Cdata | TokenKind::Character => {
                self.insert_text(token, false);
                self.frameset_not_ok();
                return;
            }
            TokenKind::Comment => {
                if let Some(parent) = self.current_node() {
                    self.append_comment(&parent, token);
                }
                return;
            }
            TokenKind::Doctype => {
                self.add_error(token);
                return;
            }
            _ => {}
        }
        let font_break = tag_is(token, TokenKind::StartTag, "font")
            && (has_attr(token, "color") || has_attr(token, "face") || has_attr(token, "size"));
        if tags_in(token, TokenKind::StartTag, FOREIGN_BREAK_START)
            || font_break
            || tags_in(token, TokenKind::EndTag, &["br", "p"])
        {
            self.add_error(token);
            while let Some(node) = self.current_node() {
                let namespace = node.0.borrow().namespace;
                if namespace == Ns::Html || mathml_ip(&node) || html_ip(&node) {
                    break;
                }
                self.pop_current_node();
            }
            self.handle_html(token);
            return;
        }
        if token.kind == TokenKind::StartTag {
            let namespace = self
                .adjusted_current()
                .map(|node| node.0.borrow().namespace)
                .unwrap_or(Ns::Html);
            self.insert_foreign(token, namespace, true);
            return;
        }
        let mut node = self.current_node();
        let names_match = node
            .as_ref()
            .map(|current| {
                let inner = current.0.borrow();
                eq_lower(&inner.name, &ascii_lower(&token.name))
            })
            .unwrap_or(false);
        if !names_match {
            self.add_error(token);
        }
        let mut index = self.open.len() as isize - 1;
        while index > 0 {
            if let Some(current) = &node {
                let same_name = {
                    let inner = current.0.borrow();
                    eq_lower(&inner.name, &ascii_lower(&token.name))
                };
                if same_name {
                    let target = current.clone();
                    loop {
                        match self.pop_current_node() {
                            Some(popped) if popped.same(&target) => break,
                            None => break,
                            _ => {}
                        }
                    }
                    return;
                }
            }
            index -= 1;
            node = self.open_at(index);
            if let Some(current) = &node {
                if current.0.borrow().namespace == Ns::Html {
                    break;
                }
            } else {
                break;
            }
        }
        if index == 0 {
            return;
        }
        self.handle_html(token);
    }
}

fn fragment_state(name: &str, noscript_as_text: bool) -> TokState {
    match name {
        "title" | "textarea" => TokState::Rcdata,
        "style" | "xmp" | "iframe" | "noembed" | "noframes" => TokState::Rawtext,
        "script" => TokState::ScriptData,
        "noscript" => {
            if noscript_as_text {
                TokState::Rawtext
            } else {
                TokState::Data
            }
        }
        "plaintext" => TokState::Plaintext,
        _ => TokState::Data,
    }
}

fn text_of(token: &Token) -> &str {
    token.data.as_str()
}

fn known(name: &str) -> bool {
    if name.bytes().any(|byte| byte.is_ascii_uppercase()) {
        known_lower(&ascii_lower(name))
    } else {
        known_lower(name)
    }
}

fn known_lower(name: &str) -> bool {
    KNOWN.iter().any(|item| *item == name)
}

fn token_error_name(token: &Token) -> String {
    let key = ascii_lower(&token.name);
    if known_lower(&key) {
        key
    } else {
        token.name.clone()
    }
}

fn node_error_name(node: &NodeRef) -> String {
    let raw = node.0.borrow().name.clone();
    let key = ascii_lower(&raw);
    if known_lower(&key) {
        key
    } else {
        raw
    }
}

fn tag_is(token: &Token, kind: TokenKind, name: &str) -> bool {
    token.kind == kind && eq_lower(&token.name, name)
}

fn tags_in(token: &Token, kind: TokenKind, set: &[&str]) -> bool {
    token.kind == kind && set.iter().any(|name| eq_lower(&token.name, name))
}

fn html_is(node: &NodeRef, name: &str) -> bool {
    let inner = node.0.borrow();
    inner.kind == NodeKind::Element && inner.namespace == Ns::Html && eq_lower(&inner.name, name)
}

fn html_in_set(node: &NodeRef, set: &[&str]) -> bool {
    let inner = node.0.borrow();
    inner.kind == NodeKind::Element
        && inner.namespace == Ns::Html
        && set.iter().any(|name| eq_lower(&inner.name, name))
}

fn ns_in(node: &NodeRef, set: &[(Ns, &str)]) -> bool {
    let inner = node.0.borrow();
    if inner.kind != NodeKind::Element {
        return false;
    }
    set.iter()
        .any(|(namespace, name)| inner.namespace == *namespace && eq_lower(&inner.name, name))
}

fn is_special(node: &NodeRef) -> bool {
    ns_in(node, SPECIAL)
}

fn mathml_ip(node: &NodeRef) -> bool {
    let inner = node.0.borrow();
    inner.namespace == Ns::MathMl && MATH_TEXT.iter().any(|name| eq_lower(&inner.name, name))
}

fn html_ip(node: &NodeRef) -> bool {
    let inner = node.0.borrow();
    if inner.kind != NodeKind::Element {
        return false;
    }
    if inner.namespace == Ns::Svg
        && SVG_HTML_BREAK
            .iter()
            .any(|name| eq_lower(&inner.name, name))
    {
        return true;
    }
    if !(inner.namespace == Ns::MathMl && eq_lower(&inner.name, "annotation-xml")) {
        return false;
    }
    triple_attr_is(&inner.attrs, "encoding", "text/html")
        || triple_attr_is(&inner.attrs, "encoding", "application/xhtml+xml")
}

fn pair_attr_is(attrs: &[(String, String)], name: &str, value: &str) -> bool {
    let key = ascii_lower(name);
    let want = ascii_lower(value);
    attrs
        .iter()
        .any(|(attr_name, attr_value)| eq_lower(attr_name, &key) && eq_lower(attr_value, &want))
}

fn triple_attr_is(attrs: &Attrs, name: &str, value: &str) -> bool {
    let key = ascii_lower(name);
    let want = ascii_lower(value);
    attrs
        .iter()
        .any(|(attr_name, attr_value, _)| eq_lower(attr_name, &key) && eq_lower(attr_value, &want))
}

fn has_attr(token: &Token, name: &str) -> bool {
    let key = ascii_lower(name);
    token
        .attrs
        .iter()
        .any(|(attr_name, _)| eq_lower(attr_name, &key))
}

fn make_element(name: &str, namespace: Ns, attrs: Attrs, line: i32) -> NodeRef {
    let node = NodeRef::new(NodeKind::Element);
    {
        let mut inner = node.0.borrow_mut();
        inner.name = name.to_string();
        inner.namespace = namespace;
        inner.attrs = attrs;
        inner.line = line;
    }
    node
}

fn html_attrs(token: &Token) -> Attrs {
    token
        .attrs
        .iter()
        .map(|(name, value)| (name.clone(), value.clone(), None))
        .collect()
}

fn foreign_attrs(token: &Token, namespace: Ns) -> Attrs {
    token
        .attrs
        .iter()
        .map(|(name, value)| {
            let mut lname = name.clone();
            if namespace == Ns::MathMl && eq_lower(&lname, "definitionurl") {
                lname = "definitionURL".to_string();
            }
            if namespace == Ns::Svg {
                if let Some(repl) = svg_attr(&ascii_lower(&lname)) {
                    lname = repl.to_string();
                }
            }
            let mut attr_ns = None;
            if let Some((mapped, mapped_ns)) = foreign_attr(&lname) {
                lname = mapped.to_string();
                attr_ns = Some(mapped_ns);
            }
            (lname, value.clone(), attr_ns)
        })
        .collect()
}

fn foreign_tag_name(token: &Token, namespace: Ns, adjust_tag: bool) -> String {
    let raw = token.name.clone();
    let key = ascii_lower(&raw);
    if namespace == Ns::Svg && adjust_tag {
        if key == "foreignobject" {
            return "foreignObject".to_string();
        }
        if !known_lower(&key) {
            if let Some(repl) = svg_tag(&key) {
                return repl.to_string();
            }
        }
    }
    if known_lower(&key) {
        key
    } else {
        raw
    }
}

fn svg_tag(key: &str) -> Option<&'static str> {
    SVG_TAGS
        .iter()
        .find(|(name, _)| *name == key)
        .map(|(_, value)| *value)
}

fn svg_attr(key: &str) -> Option<&'static str> {
    SVG_ATTRS
        .iter()
        .find(|(name, _)| *name == key)
        .map(|(_, value)| *value)
}

fn foreign_attr(name: &str) -> Option<(&'static str, Ns)> {
    FOREIGN_ATTRS
        .iter()
        .find(|(attr, _, _)| *attr == name)
        .map(|(_, mapped, namespace)| (*mapped, *namespace))
}

fn mathml_integration_token(token: &Token) -> bool {
    matches!(
        token.kind,
        TokenKind::Character | TokenKind::Whitespace | TokenKind::Null
    ) || (token.kind == TokenKind::StartTag && !tags_in(token, TokenKind::StartTag, MGLYPH_MARK))
}

fn html_integration_token(token: &Token) -> bool {
    matches!(
        token.kind,
        TokenKind::StartTag | TokenKind::Character | TokenKind::Null | TokenKind::Whitespace
    )
}

fn doctype_quirks(token: &Token) -> i32 {
    if token.force_quirks {
        return quirks::QUIRKS;
    }
    let public_id = if token.has_public_id {
        Some(token.public_id.as_str())
    } else {
        None
    };
    let system_id = if token.has_system_id {
        Some(token.system_id.as_str())
    } else {
        None
    };
    quirks::compute(
        Some(token.name.as_str()),
        public_id,
        system_id,
        token.has_system_id,
    )
}

fn illegal_doctype(token: &Token) -> bool {
    if token.name != "html" {
        return true;
    }
    if token.has_public_id {
        return true;
    }
    if token.has_system_id && token.system_id != "about:legacy-compat" {
        return true;
    }
    false
}

fn attrs_match(left: &Attrs, right: &Attrs) -> bool {
    let mut unmatched = right.len() as isize;
    for (name, value, _) in left {
        let found = right
            .iter()
            .any(|(other_name, other_value, _)| other_name == name && other_value == value);
        if found {
            unmatched -= 1;
        } else {
            return false;
        }
    }
    unmatched == 0
}

fn same_formatting(left: &NodeRef, right: &NodeRef) -> bool {
    let (left_ns, left_name, left_attrs) = {
        let inner = left.0.borrow();
        (inner.namespace, inner.name.clone(), inner.attrs.clone())
    };
    let (right_ns, right_name, right_attrs) = {
        let inner = right.0.borrow();
        (inner.namespace, inner.name.clone(), inner.attrs.clone())
    };
    left_ns == right_ns
        && eq_lower(&left_name, &ascii_lower(&right_name))
        && attrs_match(&left_attrs, &right_attrs)
}

fn clone_node(node: &NodeRef) -> NodeRef {
    let (name, namespace, line, attrs) = {
        let inner = node.0.borrow();
        (
            inner.name.clone(),
            inner.namespace,
            inner.line,
            inner.attrs.clone(),
        )
    };
    make_element(&name, namespace, attrs, line)
}

fn ruby_index(len: usize, index: isize) -> Option<usize> {
    if len == 0 {
        return None;
    }
    let len_i = len as isize;
    let idx = if index < 0 { len_i + index } else { index };
    if idx < 0 || idx >= len_i {
        None
    } else {
        Some(idx as usize)
    }
}

fn delete_at<T>(values: &mut Vec<T>, index: isize) -> Option<T> {
    let idx = ruby_index(values.len(), index)?;
    Some(values.remove(idx))
}

fn insert_entry(values: &mut Vec<FormEntry>, index: isize, entry: FormEntry) {
    if index < 0 {
        let Some(idx) = ruby_index(values.len(), index) else {
            return;
        };
        values.insert(idx, entry);
        return;
    }
    let len = values.len();
    if index as usize > len {
        values.push(entry);
        return;
    }
    values.insert(index as usize, entry);
}
