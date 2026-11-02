use crate::{
    doc::{Anchor, AnchorKind, ExtractState, PageState},
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
    normalize::{Mode, Normalized, normalize, normalize_text, source_spans_at},
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
    /// Archive member path, empty for ordinary files.
    pub member: String,
    /// Scalar offset where the member's text starts in the stored text.
    pub member_start: u32,
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
        document_in(&self.reader.searcher(), self.f, file_id)
    }

    /// Every occurrence of the query's positive literals in a file, as UTF-16 ranges of its
    /// display text.
    pub fn highlights(&self, file_id: u64, expr: &Expr, mode: Mode) -> Result<Vec<Range<u32>>> {
        let Some(doc) = self.document(file_id)? else {
            return Ok(vec![]);
        };
        let compiled = Compiled::new(expr, mode);
        Ok(bounded_highlights(&doc.text, mode, &compiled.positives(), usize::MAX).0)
    }

    /// What a preview shows, read from one snapshot so text and hits always belong together:
    /// the document (only that member's part when `member_start` names an archive member, its
    /// anchors shifted), its first `max_hits` hits and their total.
    pub fn preview(
        &self,
        file_id: u64,
        expr: &Expr,
        mode: Mode,
        member_start: Option<u32>,
        max_hits: usize,
    ) -> Result<Option<Preview>> {
        let searcher = self.reader.searcher();
        let Some(mut doc) = document_in(&searcher, self.f, file_id)? else {
            return Ok(None);
        };
        if let Some(start) = member_start {
            let end = doc
                .anchors
                .iter()
                .filter(|a| matches!(a.kind, AnchorKind::Member { .. }) && a.start > start)
                .map(|a| a.start)
                .min();
            doc.text = doc
                .text
                .chars()
                .skip(start as usize)
                .take(end.map_or(usize::MAX, |e| (e - start) as usize))
                .collect();
            doc.anchors = std::mem::take(&mut doc.anchors)
                .into_iter()
                .filter(|a| !matches!(a.kind, AnchorKind::Member { .. }) && a.start >= start && end.is_none_or(|e| a.start < e))
                .map(|a| Anchor { start: a.start - start, kind: a.kind })
                .collect();
        }
        let compiled = Compiled::new(expr, mode);
        let (highlights, total_hits) = bounded_highlights(&doc.text, mode, &compiled.positives(), max_hits);
        Ok(Some(Preview { doc, highlights, total_hits }))
    }
}

/// A document with its hits, from one snapshot.
#[derive(Debug, Clone, PartialEq)]
pub struct Preview {
    pub doc: DocView,
    /// UTF-16 ranges of `doc.text`, at most the requested number.
    pub highlights: Vec<Range<u32>>,
    pub total_hits: u64,
}

/// The first `max_hits` hits of `text` in UTF-16, and the total. Memory follows the text and
/// the kept hits, not 30 bytes per byte as a full source map did (3.1 GB for 100 MiB, R07).
fn bounded_highlights(text: &str, mode: Mode, patterns: &[Pat], max_hits: usize) -> (Vec<Range<u32>>, u64) {
    let norm = normalize_text(text, mode);
    let (total, kept) = collect_hits(&norm, patterns, max_hits);
    (to_utf16(text, &map_hits(text, &norm, mode, &kept)), total)
}

fn document_in(searcher: &Searcher, f: Fields, file_id: u64) -> Result<Option<DocView>> {
    let q = live_file(f, file_id);
    let Some(addr) = searcher.search(&q, &DocSetCollector)?.into_iter().next() else {
        return Ok(None);
    };
    let d = searcher.doc::<TantivyDocument>(addr)?;
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
            let anchors = bytes_of(&d, f.anchors);
            if anchors.windows(8).any(|w| w == b"\"member\"") {
                self.member_hits(&d, text, anchors, &mut hits);
                continue;
            }
            let norm = normalize_text(text, self.mode);
            if !self.compiled.matches(&norm) {
                continue;
            }
            // Count in the normalized text we already have; map only the first hit back to the
            // source, by normalizing just the prefix that contains it.
            let (hit_count, first) = count_hits(&norm, &self.positives);
            let (snippet, snippet_highlights) = snippet(text, &norm, self.mode, &self.positives, first);
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
                member: String::new(),
                member_start: 0,
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

impl SearchSession {
    /// An archive document: each member is matched on its own text and becomes its own hit,
    /// so a query matches when one member satisfies it (not terms spread over members).
    fn member_hits(&self, d: &TantivyDocument, text: &str, anchors: &[u8], hits: &mut Vec<Hit>) {
        let f = self.f;
        let parsed: Vec<Anchor> = serde_json::from_slice(anchors).unwrap_or_default();
        let members: Vec<(u32, String)> = parsed
            .into_iter()
            .filter_map(|a| match a.kind {
                AnchorKind::Member { name } => Some((a.start, name)),
                _ => None,
            })
            .collect();
        // Byte offset of each member start, and of the end of the text.
        let mut wanted: Vec<u32> = members.iter().map(|m| m.0).collect();
        wanted.sort_unstable();
        let mut byte_at = std::collections::HashMap::new();
        let mut k = 0;
        for (scalar, (b, _)) in text.char_indices().enumerate() {
            while k < wanted.len() && wanted[k] as usize <= scalar {
                byte_at.insert(wanted[k], b);
                k += 1;
            }
        }
        for (i, (start, name)) in members.iter().enumerate() {
            let b0 = byte_at.get(start).copied().unwrap_or(text.len());
            let b1 = members.get(i + 1).and_then(|n| byte_at.get(&n.0).copied()).unwrap_or(text.len()).max(b0);
            let segment = &text[b0..b1];
            let norm = normalize_text(segment, self.mode);
            if !self.compiled.matches(&norm) {
                continue;
            }
            let (hit_count, first) = count_hits(&norm, &self.positives);
            let (snippet, snippet_highlights) = snippet(segment, &norm, self.mode, &self.positives, first);
            hits.push(Hit {
                file_id: u64_of(d, f.file_id),
                name: str_of(d, f.name),
                dir: str_of(d, f.dir),
                mtime: i64_of(d, f.mtime),
                size: i64_of(d, f.size),
                state: ExtractState::from_code(u64_of(d, f.state)),
                hit_count,
                snippet,
                snippet_highlights,
                member: name.clone(),
                member_start: *start,
            });
        }
    }
}

/// Query verification on text that is not in the index (live scan, M4-3 / §8.7): the same
/// matching, hit counting, snippet and highlight rules as indexed search, so live hits look
/// and behave like indexed ones.
pub struct TextMatcher {
    mode: Mode,
    compiled: Compiled,
    positives: Vec<Pat>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TextHit {
    pub hit_count: u32,
    pub snippet: String,
    pub snippet_highlights: Vec<Range<u32>>,
}

impl TextMatcher {
    pub fn new(expr: &Expr, mode: Mode) -> Self {
        let compiled = Compiled::new(expr, mode);
        let positives = compiled.positives();
        Self { mode, compiled, positives }
    }

    /// None when `text` does not match.
    pub fn check(&self, text: &str) -> Option<TextHit> {
        let norm = normalize_text(text, self.mode);
        if !self.compiled.matches(&norm) {
            return None;
        }
        let (hit_count, first) = count_hits(&norm, &self.positives);
        let (snippet, snippet_highlights) = snippet(text, &norm, self.mode, &self.positives, first);
        Some(TextHit { hit_count, snippet, snippet_highlights })
    }

    /// The first `max_hits` hits as UTF-16 ranges of `text`, and how many there are (preview).
    pub fn highlights(&self, text: &str, max_hits: usize) -> (Vec<Range<u32>>, u64) {
        bounded_highlights(text, self.mode, &self.positives, max_hits)
    }
}

/// Next occurrences of one pattern, in order.
enum PatIter<'a> {
    Lit { norm: &'a str, lit: &'a str, from: usize },
    Re(regex::Matches<'a, 'a>),
}

impl Iterator for PatIter<'_> {
    type Item = Range<usize>;
    fn next(&mut self) -> Option<Range<usize>> {
        match self {
            Self::Lit { norm, lit, from } => {
                let b = *from + norm[*from..].find(*lit)?;
                // Step one scalar so overlapping occurrences ("aa" in "aaa") are all found.
                *from = b + norm[b..].chars().next().map_or(1, char::len_utf8);
                Some(b..b + lit.len())
            }
            Self::Re(m) => m.find(|m| !m.is_empty()).map(|m| m.range()),
        }
    }
}

/// Visits every hit of the patterns as normalized-byte ranges: sorted, overlaps merged. Streams
/// (one pending occurrence per pattern), so a one-letter query on 100 MiB of text does not
/// build a list of tens of millions of ranges. `visit` returns false to stop.
fn each_hit(norm: &str, patterns: &[Pat], mut visit: impl FnMut(Range<usize>) -> bool) {
    let mut iters: Vec<PatIter> = patterns
        .iter()
        .map(|p| match p {
            Pat::Lit(lit) => PatIter::Lit { norm, lit, from: 0 },
            Pat::Re(r) => PatIter::Re(r.find_iter(norm)),
        })
        .collect();
    let mut heads: Vec<Option<Range<usize>>> = iters.iter_mut().map(Iterator::next).collect();
    let mut current: Option<Range<usize>> = None;
    while let Some(i) = (0..heads.len())
        .filter(|&i| heads[i].is_some())
        .min_by_key(|&i| heads[i].as_ref().map(|r| (r.start, r.end)))
    {
        let r = heads[i].take().unwrap();
        heads[i] = iters[i].next();
        match &mut current {
            Some(c) if r.start < c.end => c.end = c.end.max(r.end),
            _ => {
                if let Some(done) = current.replace(r)
                    && !visit(done)
                {
                    return;
                }
            }
        }
    }
    if let Some(done) = current {
        visit(done);
    }
}

/// Hit count and the first `keep` hits (normalized-byte ranges).
fn collect_hits(norm: &str, patterns: &[Pat], keep: usize) -> (u64, Vec<Range<usize>>) {
    let (mut total, mut kept) = (0u64, vec![]);
    each_hit(norm, patterns, |r| {
        total += 1;
        if kept.len() < keep {
            kept.push(r);
        }
        true
    });
    (total, kept)
}

/// Source scalar ranges of normalized-byte hits (sorted, not overlapping), without a source
/// map for the whole text: only the hits' first and last output scalars are looked up. Merged
/// after mapping, as expansions such as "ﬁ" → "fi" can map neighbours onto one source scalar.
fn map_hits(text: &str, norm: &str, mode: Mode, hits: &[Range<usize>]) -> Vec<Range<usize>> {
    if hits.is_empty() {
        return vec![];
    }
    // Byte → output scalar index, in one pass over the sorted boundaries.
    let mut scalars: Vec<(usize, usize)> = Vec::with_capacity(hits.len());
    let (mut count, mut byte) = (0usize, 0usize);
    let mut chars = norm.chars();
    let mut advance = |to: usize| {
        while byte < to {
            byte += chars.next().map_or(1, char::len_utf8);
            count += 1;
        }
        count
    };
    for h in hits {
        let first = advance(h.start);
        let end = advance(h.end);
        scalars.push((first, end - 1));
    }
    let mut wanted: Vec<usize> = scalars.iter().flat_map(|&(a, b)| [a, b]).collect();
    wanted.dedup();
    let spans = source_spans_at(text, mode, &wanted);
    let span = |s: usize| wanted.binary_search(&s).ok().and_then(|i| spans.get(i));
    let mut merged: Vec<Range<usize>> = vec![];
    for &(a, b) in &scalars {
        let (Some(first), Some(last)) = (span(a), span(b)) else { continue };
        let r = first.start..last.end;
        match merged.last_mut() {
            Some(m) if r.start < m.end => m.end = m.end.max(r.end),
            _ => merged.push(r),
        }
    }
    merged
}

/// UTF-16 offsets of sorted source scalar ranges, in one pass over the text.
fn to_utf16(text: &str, ranges: &[Range<usize>]) -> Vec<Range<u32>> {
    let (mut scalar, mut unit) = (0usize, 0u32);
    let mut chars = text.chars();
    let mut advance = |to: usize| {
        while scalar < to {
            unit += chars.next().map_or(0, |c| c.len_utf16() as u32);
            scalar += 1;
        }
        unit
    };
    ranges
        .iter()
        .map(|r| {
            let a = advance(r.start);
            a..advance(r.end)
        })
        .collect()
}

/// Hit count and the normalized byte range of the first hit.
fn count_hits(norm: &str, literals: &[Pat]) -> (u32, Option<Range<usize>>) {
    let (total, first) = collect_hits(norm, literals, 1);
    (total as u32, first.into_iter().next())
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
    let mut out: Vec<Range<usize>> = collect_hits(&n.text, literals, usize::MAX)
        .1
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

const BEFORE: usize = 14;
const AFTER: usize = 32;

/// Window of ~14 characters before and ~32 after the first hit, whitespace runs collapsed,
/// ellipses at cut ends; highlights are the hits inside it in UTF-16 units of the result.
/// Cost is proportional to the hit's position, not the document length.
fn snippet(
    text: &str,
    norm: &str,
    mode: Mode,
    literals: &[Pat],
    first: Option<Range<usize>>,
) -> (String, Vec<Range<u32>>) {
    let Some(first) = first else {
        let s: String = text
            .chars()
            .take(BEFORE + AFTER)
            .map(|c| if c.is_whitespace() { ' ' } else { c })
            .collect();
        return (s.trim().to_owned(), vec![]);
    };
    // 1. Locate the first hit in source scalars.
    let Some(first) = map_hits(text, norm, mode, &[first]).into_iter().next() else {
        return (String::new(), vec![]);
    };
    // 2. All hits inside the window: only the window is normalized, however deep the hit is.
    let start = first.start.saturating_sub(BEFORE);
    let end = first.end + AFTER;
    let window: String = text.chars().skip(start).take(end - start).collect();
    let mut ranges: Vec<Range<usize>> = hit_ranges(&normalize(&window, mode), literals)
        .into_iter()
        .map(|r| r.start + start..r.end + start)
        .collect();
    // The hit itself always shows, even if context-sensitive patterns differ on the excerpt.
    if !ranges.iter().any(|r| r.start <= first.start && first.end <= r.end) {
        ranges.push(first.clone());
    }
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
    // Trailing whitespace (a line or member ending inside the window) carries no hit.
    let trimmed = out.trim_end().len();
    if trimmed < out.len() && highlights.last().is_none_or(|h| h.end as usize <= out[..trimmed].encode_utf16().count()) {
        out.truncate(trimmed);
    }
    if chars.next().is_some() {
        out.push('…');
    }
    (out, highlights)
}
