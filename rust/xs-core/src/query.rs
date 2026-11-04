use crate::normalize::{Mode, normalize};
use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Expr {
    Literal(String),
    And(Vec<Expr>),
    Or(Vec<Expr>),
    Not(Box<Expr>),
    /// `"甲 乙"~N`: every term occurs, in any order, with at most N characters between them
    /// (normalized text, paragraphs may be crossed).
    Near { terms: Vec<String>, slop: u32 },
    /// `regex:…`, matched against the mode-normalized text (case-insensitive unless the mode
    /// keeps case).
    Regex(String),
}
impl Expr {
    pub fn has_regex(&self) -> bool {
        match self {
            Self::Regex(_) => true,
            Self::And(xs) | Self::Or(xs) => xs.iter().any(Self::has_regex),
            Self::Not(x) => x.has_regex(),
            _ => false,
        }
    }
    pub fn matches(&self, text: &str, mode: Mode) -> bool {
        let text = normalize(text, mode).text;
        self.matches_normalized(&text, mode)
    }
    fn matches_normalized(&self, text: &str, mode: Mode) -> bool {
        match self {
            Self::Literal(s) => text.contains(&normalize(s, mode).text),
            Self::And(xs) => xs.iter().all(|x| x.matches_normalized(text, mode)),
            Self::Or(xs) => xs.iter().any(|x| x.matches_normalized(text, mode)),
            Self::Not(x) => !x.matches_normalized(text, mode),
            Self::Near { terms, slop } => {
                let terms: Vec<String> = terms.iter().map(|t| normalize(t, mode).text).collect();
                near_match(text, &terms, *slop)
            }
            Self::Regex(p) => regex_for(p, mode).is_ok_and(|r| r.is_match(text)),
        }
    }
}

/// Compiles a `regex:` pattern for text normalized in `mode`.
pub fn regex_for(pattern: &str, mode: Mode) -> Result<regex::Regex> {
    Ok(regex::RegexBuilder::new(pattern)
        .case_insensitive(mode == Mode::Loose)
        .size_limit(1 << 22)
        .build()?)
}

/// The longest literal (≥ 3 bytes) every match of `pattern` must contain, for trigram recall.
pub fn required_literal(pattern: &str) -> Option<String> {
    use regex_syntax::hir::{Hir, HirKind};
    fn best(h: &Hir) -> Option<String> {
        match h.kind() {
            HirKind::Literal(l) => std::str::from_utf8(&l.0).ok().map(str::to_owned),
            HirKind::Capture(c) => best(&c.sub),
            HirKind::Repetition(r) if r.min >= 1 => best(&r.sub),
            HirKind::Concat(xs) => {
                let mut found = vec![];
                let mut run = String::new();
                for x in xs {
                    if let HirKind::Literal(l) = x.kind()
                        && let Ok(s) = std::str::from_utf8(&l.0)
                    {
                        run.push_str(s);
                        continue;
                    }
                    found.push(std::mem::take(&mut run));
                    found.extend(best(x));
                }
                found.push(run);
                found.into_iter().max_by_key(String::len)
            }
            _ => None,
        }
    }
    let hir = regex_syntax::Parser::new().parse(pattern).ok()?;
    best(&hir).filter(|s| s.len() >= 3)
}

/// Whether all `terms` occur within one window whose characters outside the terms number at
/// most `slop`. Order is free; `text` and `terms` are normalized the same way.
pub fn near_match(text: &str, terms: &[String], slop: u32) -> bool {
    let mut terms: Vec<&str> = terms.iter().map(String::as_str).filter(|t| !t.is_empty()).collect();
    terms.sort_unstable();
    terms.dedup();
    if terms.is_empty() {
        return true;
    }
    let mut occ: Vec<(usize, usize, usize)> = vec![];
    for (i, t) in terms.iter().enumerate() {
        occ.extend(text.match_indices(t).map(|(b, _)| (b, b + t.len(), i)));
    }
    occ.sort_unstable();
    let used: usize = terms.iter().map(|t| t.chars().count()).sum();
    let mut count = vec![0usize; terms.len()];
    let (mut have, mut lo) = (0, 0);
    for hi in 0..occ.len() {
        if count[occ[hi].2] == 0 {
            have += 1;
        }
        count[occ[hi].2] += 1;
        while have == terms.len() {
            if count[occ[lo].2] > 1 {
                count[occ[lo].2] -= 1;
                lo += 1;
                continue;
            }
            let end = occ[lo..=hi].iter().map(|o| o.1).max().unwrap_or(occ[lo].1);
            if text[occ[lo].0..end].chars().count().saturating_sub(used) <= slop as usize {
                return true;
            }
            count[occ[lo].2] -= 1;
            have -= 1;
            lo += 1;
        }
    }
    false
}
#[derive(Debug, PartialEq)]
enum Token {
    Word(String),
    Near(Vec<String>, u32),
    Regex(String),
    Or,
    Minus,
    Left,
    Right,
}
/// Deepest nesting of groups and negations a query may have (the name query uses the same).
pub const MAX_NESTING: usize = 64;

pub fn parse(s: &str) -> Result<Expr> {
    let mut tokens = vec![];
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c.is_whitespace() {
            continue;
        }
        match c {
            '|' => tokens.push(Token::Or),
            '-' => tokens.push(Token::Minus),
            '(' => tokens.push(Token::Left),
            ')' => tokens.push(Token::Right),
            '"' => {
                let mut word = String::new();
                let mut closed = false;
                while let Some(c) = chars.next() {
                    if c == '"' {
                        closed = true;
                        break;
                    }
                    if c == '\\' {
                        word.push(
                            chars
                                .next()
                                .ok_or_else(|| anyhow::anyhow!("dangling escape"))?,
                        );
                    } else {
                        word.push(c);
                    }
                }
                if !closed || word.is_empty() {
                    bail!("empty or unclosed quoted literal");
                }
                // `"甲 乙"~N` right after the closing quote.
                if chars.peek() == Some(&'~') {
                    let rest: String = chars.clone().skip(1).take_while(char::is_ascii_digit).collect();
                    let terms: Vec<String> = word.split_whitespace().map(str::to_owned).collect();
                    if !rest.is_empty() && terms.len() >= 2 {
                        for _ in 0..=rest.len() {
                            chars.next();
                        }
                        tokens.push(Token::Near(terms, rest.parse().unwrap_or(u32::MAX)));
                        continue;
                    }
                }
                tokens.push(Token::Word(word));
            }
            _ if (c == 'r' || c == 'R')
                && chars.clone().take(5).collect::<String>().eq_ignore_ascii_case("egex:") =>
            {
                // `regex:` runs to the next whitespace and keeps every character (escapes too);
                // `\s` or `\ ` stand for spaces.
                for _ in 0..5 {
                    chars.next();
                }
                let mut pattern = String::new();
                while let Some(&c) = chars.peek() {
                    if c.is_whitespace() && !pattern.ends_with('\\') {
                        break;
                    }
                    chars.next();
                    pattern.push(c);
                }
                if pattern.is_empty() {
                    continue; // still typing
                }
                regex_for(&pattern, Mode::Loose).map_err(|e| anyhow::anyhow!("invalid regex: {e}"))?;
                tokens.push(Token::Regex(pattern));
            }
            _ => {
                let mut word = String::new();
                if c == '\\' {
                    word.push(
                        chars
                            .next()
                            .ok_or_else(|| anyhow::anyhow!("dangling escape"))?,
                    );
                } else {
                    word.push(c);
                }
                while let Some(&c) = chars.peek() {
                    if c.is_whitespace() || "|()\"".contains(c) {
                        break;
                    }
                    chars.next();
                    if c == '\\' {
                        word.push(
                            chars
                                .next()
                                .ok_or_else(|| anyhow::anyhow!("dangling escape"))?,
                        );
                    } else {
                        word.push(c);
                    }
                }
                tokens.push(Token::Word(word));
            }
        }
    }
    struct Parser {
        tokens: Vec<Token>,
        at: usize,
        /// Groups and negations open around the current token: each one is a level of recursion
        /// here and in everything that walks the tree, so pasted input cannot run the stack out.
        depth: usize,
    }
    impl Parser {
        fn nested(&mut self, f: impl FnOnce(&mut Self) -> Result<Expr>) -> Result<Expr> {
            if self.depth >= MAX_NESTING {
                bail!("查询嵌套过深：括号和排除（-）最多 {MAX_NESTING} 层");
            }
            self.depth += 1;
            let out = f(self);
            self.depth -= 1;
            out
        }
        fn or(&mut self) -> Result<Expr> {
            let mut xs = vec![self.and()?];
            while self.tokens.get(self.at) == Some(&Token::Or) {
                self.at += 1;
                xs.push(self.and()?);
            }
            Ok(if xs.len() == 1 {
                xs.remove(0)
            } else {
                Expr::Or(xs)
            })
        }
        fn and(&mut self) -> Result<Expr> {
            let mut xs = vec![];
            while self.at < self.tokens.len()
                && !matches!(self.tokens[self.at], Token::Or | Token::Right)
            {
                xs.push(self.atom()?);
            }
            if xs.is_empty() {
                bail!("missing operand");
            }
            Ok(if xs.len() == 1 {
                xs.remove(0)
            } else {
                Expr::And(xs)
            })
        }
        fn atom(&mut self) -> Result<Expr> {
            match self.tokens.get(self.at) {
                Some(Token::Minus) => {
                    self.at += 1;
                    Ok(Expr::Not(Box::new(self.nested(|p| p.atom())?)))
                }
                Some(Token::Left) => {
                    self.at += 1;
                    let x = self.nested(|p| p.or())?;
                    if self.tokens.get(self.at) != Some(&Token::Right) {
                        bail!("unclosed group")
                    }
                    self.at += 1;
                    Ok(x)
                }
                Some(Token::Word(w)) => {
                    let w = w.clone();
                    self.at += 1;
                    Ok(Expr::Literal(w))
                }
                Some(Token::Near(terms, slop)) => {
                    let e = Expr::Near { terms: terms.clone(), slop: *slop };
                    self.at += 1;
                    Ok(e)
                }
                Some(Token::Regex(p)) => {
                    let e = Expr::Regex(p.clone());
                    self.at += 1;
                    Ok(e)
                }
                _ => bail!("missing literal"),
            }
        }
    }
    let mut p = Parser { tokens, at: 0, depth: 0 };
    let out = p.or()?;
    if p.at != p.tokens.len() {
        bail!("unexpected trailing input")
    };
    Ok(out)
}
/// Conservative optimization: only positive AND literals, under unchanged caller epoch/options.
pub fn name_key(s: &str) -> String {
    // Full fold after NFC, then NFC again: combining input can change the last scalar.
    crate::normalize::full_fold(&s.nfc().collect::<String>())
        .nfc()
        .collect()
}
pub fn name_matches(e: &Expr, name: &str) -> bool {
    let key = name_key(name);
    fn run(e: &Expr, key: &str) -> bool {
        match e {
            Expr::Literal(s) => key.contains(&name_key(s)),
            Expr::And(xs) => xs.iter().all(|x| run(x, key)),
            Expr::Or(xs) => xs.iter().any(|x| run(x, key)),
            Expr::Not(x) => !run(x, key),
            Expr::Near { terms, .. } => terms.iter().all(|t| key.contains(&name_key(t))),
            Expr::Regex(p) => regex_for(p, Mode::Loose).is_ok_and(|r| r.is_match(key)),
        }
    }
    run(e, &key)
}
pub fn can_narrow(old: &Expr, new: &Expr) -> bool {
    fn literals(e: &Expr) -> Option<Vec<&str>> {
        match e {
            Expr::Literal(x) => Some(vec![x]),
            Expr::And(xs) => xs
                .iter()
                .map(literals)
                .collect::<Option<Vec<_>>>()
                .map(|v| v.into_iter().flatten().collect()),
            _ => None,
        }
    }
    let (Some(a), Some(b)) = (literals(old), literals(new)) else {
        return false;
    };
    a.iter().all(|old| {
        b.iter()
            .any(|new| new.starts_with(old) && name_key(new).contains(&name_key(old)))
    })
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NameContext {
    pub generation: u64,
    pub options: String,
    pub scope: String,
}
pub fn can_reuse(
    old: &Expr,
    new: &Expr,
    before: &NameContext,
    after: &NameContext,
    complete: bool,
) -> bool {
    complete && before == after && can_narrow(old, new)
}
