use crate::{
    doc::{Anchor, ExtractState, PageState},
    schema::{Fields, dir_term, open_existing},
};
use anyhow::Result;
use std::{
    ops::{Bound, Range},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
use tantivy::{
    DocAddress, Index, IndexReader, ReloadPolicy, Searcher, TantivyDocument, Term,
    collector::{Count, DocSetCollector},
    query::{BooleanQuery, Occur, Query, RangeQuery, TermQuery},
    schema::{IndexRecordOption, Value},
};
use xs_core::{
    normalize::{Mode, Normalized, normalize, normalize_prefix, normalize_text},
    query::{Expr, name_key, near_match, regex_for, required_literal},
};

/// How candidates were found, so the UI can explain cost and completeness (UI-SPEC §7).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Recall {
    /// Every positive literal has ≥ 3 UTF-8 bytes: trigram intersection.
    Trigram,
    /// Uses a 2-byte prefix range plus the trailing-pair marker; still complete.
    Pair,
    /// Long terms find candidates; shorter AND terms are only verified ("先用长词找候选").
    LongTermsThenVerify,
    /// No usable term (1-byte literal, pure NOT…): every document's stored text is scanned.
    Scan,
}

#[derive(Debug, Clone)]
pub struct SearchRequest {
    pub expr: Expr,
    pub mode: Mode,
    /// Absolute directories (`dir:`); OR-ed. Empty = everywhere.
    pub dirs: Vec<String>,
    /// Extensions without dot (`ext:`); OR-ed.
    pub exts: Vec<String>,
    /// Content scope ids; OR-ed. Empty = all scopes.
    pub scopes: Vec<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub file_id: u64,
    pub name: String,
    pub dir: String,
    pub mtime: i64,
    pub size: i64,
    pub state: ExtractState,
    /// Occurrences of the positive literals in this file.
    pub hit_count: u32,
    /// About 14 characters before and 32 after the first hit (UI-SPEC §4.3), whitespace collapsed.
    pub snippet: String,
    /// UTF-16 ranges inside `snippet` (NSString / NSTextView offsets).
    pub snippet_highlights: Vec<Range<u32>>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Batch {
    pub hits: Vec<Hit>,
    pub candidates: usize,
    pub verified: usize,
    pub done: bool,
}

/// Searches one immutable snapshot. Create it per query; it never sees later commits, so
/// paging and progressive verification stay consistent.
pub struct ContentReader {
    index: Index,
    reader: IndexReader,
    f: Fields,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DocView {
    pub file_id: u64,
    pub op_seq: u64,
    pub revision: u64,
    pub name: String,
    pub dir: String,
    pub mtime: i64,
    pub size: i64,
    pub text: String,
    pub anchors: Vec<Anchor>,
    pub pages: Vec<PageState>,
    pub state: ExtractState,
}

impl ContentReader {
    /// Opens an index written by another process; new commits appear after `reload`
    /// (or automatically shortly after each commit).
    pub fn open(path: &Path) -> Result<Self> {
        let (index, _) = open_existing(path)?;
        let f = Fields::of(&index.schema())?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::OnCommitWithDelay)
            // M0-B 5.3: a doc store block cache makes repeated reads of hot documents cheap.
            .doc_store_cache_num_blocks(100)
            .try_into()?;
        Ok(Self { index, reader, f })
    }

    pub fn reload(&self) -> Result<()> {
        Ok(self.reader.reload()?)
    }

    /// Live documents in the current snapshot.
    pub fn live_count(&self) -> Result<usize> {
        let q = TermQuery::new(
            Term::from_field_u64(self.f.live, 1),
            IndexRecordOption::Basic,
        );
        Ok(self.reader.searcher().search(&q, &Count)?)
    }

    pub fn index(&self) -> &Index {
        &self.index
    }

    pub fn session(&self, req: SearchRequest) -> Result<SearchSession> {
        SearchSession::new(self.reader.searcher(), self.f, req)
    }

    pub fn document(&self, file_id: u64) -> Result<Option<DocView>> {
        let searcher = self.reader.searcher();
        let q = live_file(self.f, file_id);
        let Some(addr) = searcher.search(&q, &DocSetCollector)?.into_iter().next() else {
            return Ok(None);
        };
        let d = searcher.doc::<TantivyDocument>(addr)?;
        let f = self.f;
        Ok(Some(DocView {
            file_id,
            op_seq: u64_of(&d, f.op_seq),
            revision: u64_of(&d, f.revision),
            name: str_of(&d, f.name),
            dir: str_of(&d, f.dir),
            mtime: i64_of(&d, f.mtime),
            size: i64_of(&d, f.size),
            text: str_of(&d, f.text),
            anchors: serde_json::from_slice(bytes_of(&d, f.anchors)).unwrap_or_default(),
            pages: serde_json::from_slice(bytes_of(&d, f.pages)).unwrap_or_default(),
            state: ExtractState::from_code(u64_of(&d, f.state)),
        }))
    }

    /// Every occurrence of the query's positive literals in a file, as UTF-16 ranges of its
    /// display text (preview highlighting and "第 n/N 处").
    pub fn highlights(&self, file_id: u64, expr: &Expr, mode: Mode) -> Result<Vec<Range<u32>>> {
        let Some(doc) = self.document(file_id)? else {
            return Ok(vec![]);
        };
        let compiled = Compiled::new(expr, mode);
        let ranges = hit_ranges(&normalize(&doc.text, mode), &compiled.positives());
        let utf16 = utf16_offsets(&doc.text);
        Ok(ranges
            .into_iter()
            .map(|r| utf16[r.start] as u32..utf16[r.end] as u32)
            .collect())
    }
}

fn live_file(f: Fields, file_id: u64) -> BooleanQuery {
    BooleanQuery::new(vec![
        (
            Occur::Must,
            Box::new(TermQuery::new(
                Term::from_field_u64(f.file_id, file_id),
                IndexRecordOption::Basic,
            )),
        ),
        (
            Occur::Must,
            Box::new(TermQuery::new(
                Term::from_field_u64(f.live, 1),
                IndexRecordOption::Basic,
            )),
        ),
    ])
}

fn u64_of(d: &TantivyDocument, f: tantivy::schema::Field) -> u64 {
    d.get_first(f).and_then(|v| v.as_u64()).unwrap_or(0)
}
fn i64_of(d: &TantivyDocument, f: tantivy::schema::Field) -> i64 {
    d.get_first(f).and_then(|v| v.as_i64()).unwrap_or(0)
}
fn str_of(d: &TantivyDocument, f: tantivy::schema::Field) -> String {
    d.get_first(f)
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_owned()
}
fn bytes_of(d: &TantivyDocument, f: tantivy::schema::Field) -> &[u8] {
    d.get_first(f).and_then(|v| v.as_bytes()).unwrap_or(b"[]")
}

/// Query with literals normalized (and regexes compiled) once for the verification mode.
enum Compiled {
    Literal(String),
    And(Vec<Compiled>),
    Or(Vec<Compiled>),
    Not(Box<Compiled>),
    Near(Vec<String>, u32),
    Regex(regex::Regex),
}

/// What a hit can point at: a normalized literal or a regex match.
#[derive(Clone)]
enum Pat {
    Lit(String),
    Re(regex::Regex),
}

impl Compiled {
    fn new(e: &Expr, mode: Mode) -> Self {
        match e {
            Expr::Literal(s) => Self::Literal(normalize_text(s, mode)),
            Expr::And(xs) => Self::And(xs.iter().map(|x| Self::new(x, mode)).collect()),
            Expr::Or(xs) => Self::Or(xs.iter().map(|x| Self::new(x, mode)).collect()),
            Expr::Not(x) => Self::Not(Box::new(Self::new(x, mode))),
            Expr::Near { terms, slop } => Self::Near(terms.iter().map(|t| normalize_text(t, mode)).collect(), *slop),
            // Patterns were validated by the parser; an impossible one matches nothing.
            Expr::Regex(p) => Self::Regex(regex_for(p, mode).unwrap_or_else(|_| regex::Regex::new(r"[^\s\S]").unwrap())),
        }
    }

    fn matches(&self, text: &str) -> bool {
        match self {
            Self::Literal(s) => text.contains(s.as_str()),
            Self::And(xs) => xs.iter().all(|x| x.matches(text)),
            Self::Or(xs) => xs.iter().any(|x| x.matches(text)),
            Self::Not(x) => !x.matches(text),
            Self::Near(terms, slop) => near_match(text, terms, *slop),
            Self::Regex(r) => r.is_match(text),
        }
    }

    /// Literals and patterns not under a NOT: the ones a hit can point at.
    fn positives(&self) -> Vec<Pat> {
        fn walk(c: &Compiled, lits: &mut Vec<String>, res: &mut Vec<Pat>) {
            match c {
                Compiled::Literal(s) => lits.push(s.clone()),
                Compiled::Near(terms, _) => lits.extend(terms.iter().cloned()),
                Compiled::Regex(r) => res.push(Pat::Re(r.clone())),
                Compiled::And(xs) | Compiled::Or(xs) => xs.iter().for_each(|x| walk(x, lits, res)),
                Compiled::Not(_) => {}
            }
        }
        let (mut lits, mut out) = (vec![], vec![]);
        walk(self, &mut lits, &mut out);
        lits.retain(|s| !s.is_empty());
        lits.sort();
        lits.dedup();
        out.extend(lits.into_iter().map(Pat::Lit));
        out
    }
}

/// Recall plan over loose trigrams. `None` = no restriction (every live document is a candidate).
/// Correctness argument (§8.3): any match in any mode is a substring of the loose-normalized
/// text after per-scalar mapping, so its trigrams/trailing pair are indexed.
struct Planner {
    f: Fields,
    used_pair: bool,
    dropped_short: bool,
}

impl Planner {
    fn term(&self, g: u64) -> Box<dyn Query> {
        Box::new(TermQuery::new(
            Term::from_field_u64(self.f.tri, g),
            IndexRecordOption::Basic,
        ))
    }

    fn plan(&mut self, e: &Expr) -> Option<Box<dyn Query>> {
        match e {
            Expr::Literal(t) => {
                let n = normalize_text(t, Mode::Loose);
                let b = n.as_bytes();
                match b.len() {
                    0 | 1 => None,
                    2 => {
                        // Pair inside the text: any trigram starting with it; at the very end: the
                        // tagged trailing-pair term.
                        self.used_pair = true;
                        let pair = ((b[0] as u64) << 8) | b[1] as u64;
                        Some(Box::new(BooleanQuery::union(vec![
                            Box::new(RangeQuery::new(
                                Bound::Included(Term::from_field_u64(self.f.tri, pair << 8)),
                                Bound::Included(Term::from_field_u64(
                                    self.f.tri,
                                    (pair << 8) | 255,
                                )),
                            )),
                            self.term((1 << 24) | pair),
                        ])))
                    }
                    _ => {
                        let mut grams: Vec<u64> = b
                            .windows(3)
                            .map(|w| ((w[0] as u64) << 16) | ((w[1] as u64) << 8) | w[2] as u64)
                            .collect();
                        grams.sort_unstable();
                        grams.dedup();
                        Some(Box::new(BooleanQuery::intersection(
                            grams.into_iter().map(|g| self.term(g)).collect(),
                        )))
                    }
                }
            }
            Expr::And(xs) => {
                let parts: Vec<Option<Box<dyn Query>>> = xs.iter().map(|x| self.plan(x)).collect();
                let restricting: Vec<Box<dyn Query>> = parts.into_iter().flatten().collect();
                if restricting.len() < xs.len() && !restricting.is_empty() {
                    self.dropped_short = true;
                }
                if restricting.is_empty() {
                    None
                } else {
                    Some(Box::new(BooleanQuery::intersection(restricting)))
                }
            }
            Expr::Or(xs) => {
                let parts: Vec<Option<Box<dyn Query>>> = xs.iter().map(|x| self.plan(x)).collect();
                if parts.iter().any(Option::is_none) {
                    return None;
                }
                Some(Box::new(BooleanQuery::union(
                    parts.into_iter().flatten().collect(),
                )))
            }
            Expr::Near { terms, .. } => self.plan(&Expr::And(terms.iter().cloned().map(Expr::Literal).collect())),
            // A regex narrows recall only through a literal every match must contain.
            Expr::Regex(p) => required_literal(p).and_then(|l| self.plan(&Expr::Literal(l))),
            // NOT cannot narrow recall; it is applied during verification.
            Expr::Not(_) => None,
        }
    }
}

/// One query over one snapshot. Call `next` until `done`: candidates are verified newest
/// first within a time budget, so the first screen arrives quickly and heavy queries can be
/// shown as "仍在搜索… 已核验 x / y" and stopped (§8.4, UI-SPEC §7). The result set is complete
/// when `done` is reached; nothing is dropped by truncation.
pub struct SearchSession {
    searcher: Searcher,
    f: Fields,
    mode: Mode,
    compiled: Compiled,
    positives: Vec<Pat>,
    candidates: Vec<DocAddress>,
    next: usize,
    pub recall: Recall,
}

impl SearchSession {
    fn new(searcher: Searcher, f: Fields, req: SearchRequest) -> Result<Self> {
        let mut planner = Planner {
            f,
            used_pair: false,
            dropped_short: false,
        };
        let recall_query = planner.plan(&req.expr);
        let recall = match (&recall_query, planner.dropped_short, planner.used_pair) {
            (None, _, _) => Recall::Scan,
            (Some(_), true, _) => Recall::LongTermsThenVerify,
            (Some(_), false, true) => Recall::Pair,
            (Some(_), false, false) => Recall::Trigram,
        };
        let mut clauses: Vec<(Occur, Box<dyn Query>)> = vec![(
            Occur::Must,
            Box::new(TermQuery::new(
                Term::from_field_u64(f.live, 1),
                IndexRecordOption::Basic,
            )),
        )];
        if let Some(q) = recall_query {
            clauses.push((Occur::Must, q));
        }
        let any_of = |terms: Vec<Term>| -> Box<dyn Query> {
            Box::new(BooleanQuery::union(
                terms
                    .into_iter()
                    .map(|t| {
                        Box::new(TermQuery::new(t, IndexRecordOption::Basic)) as Box<dyn Query>
                    })
                    .collect(),
            ))
        };
        if !req.dirs.is_empty() {
            clauses.push((
                Occur::Must,
                any_of(
                    req.dirs
                        .iter()
                        .map(|d| Term::from_field_text(f.dir_prefix, &dir_term(d)))
                        .collect(),
                ),
            ));
        }
        if !req.exts.is_empty() {
            clauses.push((
                Occur::Must,
                any_of(
                    req.exts
                        .iter()
                        .map(|e| Term::from_field_text(f.ext, &name_key(e.trim_start_matches('.'))))
                        .collect(),
                ),
            ));
        }
        if !req.scopes.is_empty() {
            clauses.push((
                Occur::Must,
                any_of(
                    req.scopes
                        .iter()
                        .map(|s| Term::from_field_u64(f.scope, *s))
                        .collect(),
                ),
            ));
        }
        let addrs = searcher.search(&BooleanQuery::new(clauses), &DocSetCollector)?;
        // Newest first: recent files are the likeliest answers and reach the first screen first.
        let mut keyed: Vec<(i64, DocAddress)> = Vec::with_capacity(addrs.len());
        for seg_ord in 0..searcher.segment_readers().len() {
            let col = searcher
                .segment_reader(seg_ord as u32)
                .fast_fields()
                .i64("mtime")?;
            for a in addrs.iter().filter(|a| a.segment_ord as usize == seg_ord) {
                keyed.push((col.first(a.doc_id).unwrap_or(0), *a));
            }
        }
        keyed.sort_unstable_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        let compiled = Compiled::new(&req.expr, req.mode);
        let positives = compiled.positives();
        Ok(Self {
            searcher,
            f,
            mode: req.mode,
            compiled,
            positives,
            candidates: keyed.into_iter().map(|(_, a)| a).collect(),
            next: 0,
            recall,
        })
    }

    pub fn candidates(&self) -> usize {
        self.candidates.len()
    }

    /// Verifies candidates until `budget` elapses, `max_hits` matches are found, `cancel` is set,
    /// or all candidates are done. Always makes progress on at least one candidate.
    pub fn next(
        &mut self,
        budget: Duration,
        max_hits: usize,
        cancel: &AtomicBool,
    ) -> Result<Batch> {
        let start = Instant::now();
        let mut hits = vec![];
        let f = self.f;
        let mut progressed = 0;
        while self.next < self.candidates.len() {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            if progressed > 0 && (start.elapsed() >= budget || hits.len() >= max_hits) {
                break;
            }
            progressed += 1;
            let addr = self.candidates[self.next];
            self.next += 1;
            let d = self.searcher.doc::<TantivyDocument>(addr)?;
            let text = d.get_first(f.text).and_then(|v| v.as_str()).unwrap_or("");
            let norm = normalize_text(text, self.mode);
            if !self.compiled.matches(&norm) {
                continue;
            }
            // Count in the normalized text we already have; map only the first hit back to the
            // source, by normalizing just the prefix that contains it.
            let (hit_count, first_end) = count_hits(&norm, &self.positives);
            let (snippet, snippet_highlights) =
                snippet(text, self.mode, &self.positives, first_end);
            hits.push(Hit {
                file_id: u64_of(&d, f.file_id),
                name: str_of(&d, f.name),
                dir: str_of(&d, f.dir),
                mtime: i64_of(&d, f.mtime),
                size: i64_of(&d, f.size),
                state: ExtractState::from_code(u64_of(&d, f.state)),
                hit_count,
                snippet,
                snippet_highlights,
            });
        }
        Ok(Batch {
            hits,
            candidates: self.candidates.len(),
            verified: self.next,
            done: self.next >= self.candidates.len(),
        })
    }
}

/// Normalized-byte ranges of every occurrence of `literals` (normalized for the mode), sorted,
/// overlaps merged.
fn occurrences(norm: &str, literals: &[Pat]) -> Vec<Range<usize>> {
    let mut out: Vec<Range<usize>> = vec![];
    for pat in literals {
        let lit = match pat {
            Pat::Lit(l) => l,
            Pat::Re(r) => {
                out.extend(r.find_iter(norm).filter(|m| !m.is_empty()).map(|m| m.range()));
                continue;
            }
        };
        let mut from = 0;
        while let Some(pos) = norm[from..].find(lit.as_str()) {
            let b = from + pos;
            out.push(b..b + lit.len());
            // Step one scalar so overlapping occurrences ("aa" in "aaa") are all found.
            from = b + norm[b..].chars().next().map_or(1, char::len_utf8);
        }
    }
    out.sort_by_key(|r| (r.start, r.end));
    let mut merged: Vec<Range<usize>> = vec![];
    for r in out {
        match merged.last_mut() {
            Some(last) if r.start < last.end => last.end = last.end.max(r.end),
            _ => merged.push(r),
        }
    }
    merged
}

/// Hit count and the normalized byte offset where the first hit ends.
fn count_hits(norm: &str, literals: &[Pat]) -> (u32, Option<usize>) {
    let occ = occurrences(norm, literals);
    (occ.len() as u32, occ.first().map(|r| r.end))
}

/// Source scalar ranges of every hit in an already normalized text (merged after mapping:
/// expansions such as "ﬁ" → "fi" can map neighbouring hits onto one source scalar).
fn hit_ranges(n: &Normalized, literals: &[Pat]) -> Vec<Range<usize>> {
    let mut scalar_at = vec![0usize; n.text.len() + 1];
    let mut count = 0;
    for (b, _) in n.text.char_indices() {
        scalar_at[b] = count;
        count += 1;
    }
    scalar_at[n.text.len()] = count;
    let mut out: Vec<Range<usize>> = occurrences(&n.text, literals)
        .into_iter()
        .filter_map(|r| n.source_range(scalar_at[r.start]..scalar_at[r.end]))
        .collect();
    out.sort_by_key(|r| (r.start, r.end));
    let mut merged: Vec<Range<usize>> = vec![];
    for r in out {
        match merged.last_mut() {
            Some(last) if r.start < last.end => last.end = last.end.max(r.end),
            _ => merged.push(r),
        }
    }
    merged
}

/// UTF-16 offset of each scalar boundary (index = scalar offset).
fn utf16_offsets(text: &str) -> Vec<usize> {
    let mut out = Vec::with_capacity(text.len() + 1);
    let mut u = 0;
    out.push(0);
    for c in text.chars() {
        u += c.len_utf16();
        out.push(u);
    }
    out
}

const BEFORE: usize = 14;
const AFTER: usize = 32;

/// Window of ~14 characters before and ~32 after the first hit, whitespace runs collapsed,
/// ellipses at cut ends; highlights are the hits inside it in UTF-16 units of the result.
/// Cost is proportional to the hit's position, not the document length.
fn snippet(
    text: &str,
    mode: Mode,
    literals: &[Pat],
    first_end: Option<usize>,
) -> (String, Vec<Range<u32>>) {
    let Some(first_end) = first_end else {
        let s: String = text
            .chars()
            .take(BEFORE + AFTER)
            .map(|c| if c.is_whitespace() { ' ' } else { c })
            .collect();
        return (s.trim().to_owned(), vec![]);
    };
    // 1. Locate the first hit in source scalars.
    let head = normalize_prefix(text, mode, first_end, usize::MAX);
    let Some(first) = hit_ranges(&head, literals).into_iter().next() else {
        return (String::new(), vec![]);
    };
    // 2. All hits inside the window.
    let start = first.start.saturating_sub(BEFORE);
    let end = first.end + AFTER;
    let window = normalize_prefix(text, mode, usize::MAX, end);
    let ranges: Vec<Range<usize>> = hit_ranges(&window, literals)
        .into_iter()
        .filter(|r| r.end > start)
        .collect();
    // 3. Render.
    let mut chars = text.chars().skip(start);
    let mut out = String::new();
    let mut highlights = vec![];
    let mut u16len = 0u32;
    if start > 0 {
        out.push('…');
        u16len += 1;
    }
    let mut last_space = false;
    let mut open: Option<u32> = None;
    for i in start..end {
        let Some(ch) = chars.next() else { break };
        let in_hit = ranges.iter().any(|r| r.start <= i && i < r.end);
        match (in_hit, open) {
            (true, None) => open = Some(u16len),
            (false, Some(s)) => {
                highlights.push(s..u16len);
                open = None;
            }
            _ => {}
        }
        let c = if ch.is_whitespace() { ' ' } else { ch };
        if c == ' ' && last_space && !in_hit {
            continue;
        }
        last_space = c == ' ';
        out.push(c);
        u16len += c.len_utf16() as u32;
    }
    if let Some(s) = open {
        highlights.push(s..u16len);
    }
    if chars.next().is_some() {
        out.push('…');
    }
    (out, highlights)
}
