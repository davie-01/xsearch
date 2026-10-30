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
}
impl Expr {
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
        }
    }
}
#[derive(Debug, PartialEq)]
enum Token {
    Word(String),
    Or,
    Minus,
    Left,
    Right,
}
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
                tokens.push(Token::Word(word));
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
    }
    impl Parser {
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
                    Ok(Expr::Not(Box::new(self.atom()?)))
                }
                Some(Token::Left) => {
                    self.at += 1;
                    let x = self.or()?;
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
                _ => bail!("missing literal"),
            }
        }
    }
    let mut p = Parser { tokens, at: 0 };
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
