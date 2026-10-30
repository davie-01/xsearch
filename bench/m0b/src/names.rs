//! Data-layout experiment: literal NFC/full-fold names only. No pinyin or fuzzy aliases.
use anyhow::{Result, ensure};
use serde::Serialize;
use std::{collections::HashMap, ops::Range, time::Instant};
use xs_core::query::name_key;
#[derive(Clone)]
struct Entry {
    id: u64,
    dir: String,
    name: String,
    key: String,
    size: u64,
    mtime: u64,
}
fn entry(id: u64, dir: String, name: String) -> Entry {
    let key = name_key(&name);
    Entry {
        id,
        dir,
        name,
        key,
        size: id * 13,
        mtime: id % 7919,
    }
}
#[derive(Default)]
struct Strings {
    data: Vec<u8>,
    offsets: Vec<u32>,
}
impl Strings {
    fn new() -> Self {
        Self {
            data: vec![],
            offsets: vec![0],
        }
    }
    fn add(&mut self, s: &str) {
        self.data.extend_from_slice(s.as_bytes());
        self.offsets.push(
            self.data
                .len()
                .try_into()
                .expect("fixture exceeds 4GB string pool"),
        );
    }
    fn get(&self, i: usize) -> &str {
        std::str::from_utf8(&self.data[self.offsets[i] as usize..self.offsets[i + 1] as usize])
            .unwrap()
    }
    fn len(&self) -> usize {
        self.offsets.len() - 1
    }
    fn bytes(&self) -> usize {
        self.data.capacity() + self.offsets.capacity() * 4
    }
}
#[derive(Clone, Copy, Debug, Serialize)]
enum Layout {
    Columns,
    DirectoryColumns,
    DirectoryIntern,
    DirectoryInternBitmap,
}
impl Layout {
    fn ordered(self) -> bool {
        !matches!(self, Self::Columns)
    }
    fn intern(self) -> bool {
        matches!(self, Self::DirectoryIntern | Self::DirectoryInternBitmap)
    }
    fn bitmap(self) -> bool {
        matches!(self, Self::DirectoryInternBitmap)
    }
}
struct Snapshot {
    layout: Layout,
    ids: Vec<u64>,
    dirs: Vec<u32>,
    slots: Vec<u32>,
    sizes: Vec<u64>,
    mtimes: Vec<u64>,
    names: Strings,
    keys: Strings,
    directory: Vec<String>,
    masks: Vec<u64>,
}
fn path_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    a.split('/').cmp(b.split('/'))
}
fn in_scope(dir: &str, scope: &str) -> bool {
    scope == "/"
        || dir == scope
        || dir
            .strip_prefix(scope)
            .is_some_and(|suffix| suffix.starts_with('/'))
}
fn mask(s: &str) -> u64 {
    s.bytes().fold(0, |a, b| a | (1u64 << (b % 64)))
}
impl Snapshot {
    fn build(rows: &[Entry], layout: Layout) -> Self {
        let mut directory = rows.iter().map(|r| r.dir.clone()).collect::<Vec<_>>();
        directory.sort_by(|a, b| path_cmp(a, b));
        directory.dedup();
        let dmap = directory
            .iter()
            .enumerate()
            .map(|(i, d)| (d.as_str(), i as u32))
            .collect::<HashMap<_, _>>();
        let mut order = (0..rows.len()).collect::<Vec<_>>();
        if layout.ordered() {
            order.sort_unstable_by_key(|i| (dmap[rows[*i].dir.as_str()], rows[*i].id));
        }
        let mut out = Self {
            layout,
            ids: vec![],
            dirs: vec![],
            slots: vec![],
            sizes: vec![],
            mtimes: vec![],
            names: Strings::new(),
            keys: Strings::new(),
            directory: directory.clone(),
            masks: vec![],
        };
        let mut pool = HashMap::<&str, u32>::new();
        for i in order {
            let e = &rows[i];
            out.ids.push(e.id);
            out.dirs.push(dmap[e.dir.as_str()]);
            out.sizes.push(e.size);
            out.mtimes.push(e.mtime);
            let slot = if layout.intern() {
                if let Some(s) = pool.get(e.name.as_str()) {
                    *s
                } else {
                    let s = out.names.len() as u32;
                    pool.insert(&e.name, s);
                    out.names.add(&e.name);
                    out.keys.add(&e.key);
                    s
                }
            } else {
                let s = out.names.len() as u32;
                out.names.add(&e.name);
                out.keys.add(&e.key);
                s
            };
            if layout.intern() {
                out.slots.push(slot);
            }
        }
        if layout.bitmap() {
            out.masks = vec![0; out.keys.len().div_ceil(64)];
            for i in 0..out.keys.len() {
                out.masks[i / 64] |= mask(out.keys.get(i));
            }
        }
        // Compact all variants equally. Otherwise insertion order changes Vec growth slack
        // and could falsely look like a directory-layout memory saving.
        out.ids.shrink_to_fit();
        out.dirs.shrink_to_fit();
        out.slots.shrink_to_fit();
        out.sizes.shrink_to_fit();
        out.mtimes.shrink_to_fit();
        out.names.data.shrink_to_fit();
        out.names.offsets.shrink_to_fit();
        out.keys.data.shrink_to_fit();
        out.keys.offsets.shrink_to_fit();
        out.directory.shrink_to_fit();
        out.masks.shrink_to_fit();
        out
    }
    fn bytes(&self) -> usize {
        self.ids.capacity() * 8
            + self.dirs.capacity() * 4
            + self.slots.capacity() * 4
            + self.sizes.capacity() * 8
            + self.mtimes.capacity() * 8
            + self.names.bytes()
            + self.keys.bytes()
            + self.directory.capacity() * std::mem::size_of::<String>()
            + self.directory.iter().map(String::capacity).sum::<usize>()
            + self.masks.capacity() * 8
    }
    fn range(&self, scope: &str) -> Range<usize> {
        if !self.layout.ordered() || scope == "/" {
            return 0..self.ids.len();
        }
        let start = self
            .directory
            .partition_point(|d| path_cmp(d, scope).is_lt());
        let end = start
            + self.directory[start..]
                .iter()
                .take_while(|d| in_scope(d, scope))
                .count();
        self.dirs.partition_point(|d| (*d as usize) < start)
            ..self.dirs.partition_point(|d| (*d as usize) < end)
    }
    fn search(
        &self,
        q: &Query,
        delta: &HashMap<u64, Option<Entry>>,
    ) -> (Vec<(u64, u64, u64)>, usize) {
        let range = self.range(&q.scope);
        let mut comparisons = 0;
        let mut matches = vec![];
        // Scope first: don't scan a million unique names to answer a tiny subtree query.
        let pooled = self.layout.intern() && range.len() >= self.keys.len();
        let mut pool_hits = vec![];
        if pooled {
            pool_hits = vec![false; self.keys.len()];
            let required = q.terms.iter().fold(0, |a, s| a | mask(s));
            for (i, hit) in pool_hits.iter_mut().enumerate() {
                if self.layout.bitmap() && self.masks[i / 64] & required != required {
                    continue;
                }
                comparisons += 1;
                *hit = q.matches(self.keys.get(i));
            }
        }
        let scopes = self
            .directory
            .iter()
            .map(|d| in_scope(d, &q.scope))
            .collect::<Vec<_>>();
        for i in range {
            if !scopes[self.dirs[i] as usize]
                || (!delta.is_empty() && delta.contains_key(&self.ids[i]))
            {
                continue;
            }
            let slot = if self.layout.intern() {
                self.slots[i] as usize
            } else {
                i
            };
            let hit = if pooled {
                pool_hits[slot]
            } else {
                comparisons += 1;
                q.matches(self.keys.get(slot))
            };
            if hit {
                matches.push((self.ids[i], self.mtimes[i], self.sizes[i]));
            }
        }
        for e in delta.values().flatten() {
            if in_scope(&e.dir, &q.scope) {
                comparisons += 1;
                if q.matches(&e.key) {
                    matches.push((e.id, e.mtime, e.size));
                }
            }
        }
        // ID ordering gives deterministic complete-result comparison; no product ranking claim.
        matches.sort_unstable();
        (matches, comparisons)
    }
}
struct Query {
    label: String,
    terms: Vec<String>,
    scope: String,
}
impl Query {
    fn new(label: &str, terms: &[&str], scope: &str) -> Self {
        Self {
            label: label.into(),
            terms: terms.iter().map(|x| name_key(x)).collect(),
            scope: scope.into(),
        }
    }
    fn matches(&self, name: &str) -> bool {
        self.terms.iter().all(|t| name.contains(t))
    }
}
fn queries() -> Vec<Query> {
    vec![
        Query::new("chinese_single", &["数"], "/"),
        Query::new("chinese_pair", &["数据"], "/"),
        Query::new("substring", &["port"], "/"),
        Query::new("short_ascii", &["AI"], "/"),
        Query::new("numeric", &["2202"], "/"),
        Query::new("literal_letters_no_pinyin", &["sj"], "/"),
        Query::new("punctuation", &["[v2]"], "/"),
        Query::new("and", &["report", "pdf"], "/"),
        Query::new("scope_A", &["数据"], "/Work/A"),
        Query::new("scope_nested", &["report"], "/Work/A/0002"),
        Query::new("unicode_nfc", &["café"], "/"),
        Query::new("no_match", &["不存在_xyz"], "/"),
    ]
}
fn dataset(n: usize, repeat: bool) -> Vec<Entry> {
    let templates = [
        "数据共享方案.docx",
        "report-2202.pdf",
        "AI_notes.txt",
        "invoice[v2].xlsx",
        "sj_literal.md",
        "cafe\u{301}.txt",
        "😀合同.docx",
        "Straße.txt",
    ];
    let mut out = (0..n)
        .map(|i| {
            let name = if repeat {
                format!("{}-{}", (i / 8) % 32, templates[i % templates.len()])
            } else {
                format!("{:08}-{}", i, templates[i % templates.len()])
            };
            let branch = if (i / 256) % 5 == 0 { "Archive" } else { "A" };
            entry(
                i as u64,
                format!("/Work/{}/{:04}/{:06}", branch, (i / 256) % 32, i / 256),
                name,
            )
        })
        .collect::<Vec<_>>();
    // Deliberately ungrouped ingestion order, stable across runs.
    let mut x = 0x5160u64;
    for i in (1..out.len()).rev() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.swap(i, x as usize % (i + 1));
    }
    out
}
fn mutations(rows: &[Entry]) -> HashMap<u64, Option<Entry>> {
    let mut delta = HashMap::new();
    let count = (rows.len() / 100).max(4);
    for (i, e) in rows.iter().take(count).enumerate() {
        let replacement = match i % 4 {
            0 => None,
            1 => Some(entry(e.id, "/Outside".into(), "数据 moved-out.docx".into())),
            2 => Some(entry(
                e.id,
                "/Work/A/0002/00".into(),
                format!("report-moved-in-{}.pdf", e.id),
            )),
            _ => Some(entry(
                e.id,
                e.dir.clone(),
                format!("renamed 数据[v2]-{}.docx", e.id),
            )),
        };
        delta.insert(e.id, replacement);
    }
    delta.insert(
        rows.len() as u64 + 99,
        Some(entry(
            rows.len() as u64 + 99,
            "/Work/A/0002/00".into(),
            "report-new.pdf".into(),
        )),
    );
    delta
}
fn logical(rows: &[Entry], delta: &HashMap<u64, Option<Entry>>) -> Vec<Entry> {
    let mut out = rows
        .iter()
        .filter(|r| !delta.contains_key(&r.id))
        .cloned()
        .collect::<Vec<_>>();
    out.extend(delta.values().flatten().cloned());
    out
}
fn oracle(rows: &[Entry], q: &Query) -> Vec<(u64, u64, u64)> {
    let mut out = rows
        .iter()
        .filter(|e| in_scope(&e.dir, &q.scope) && q.matches(&e.key))
        .map(|e| (e.id, e.mtime, e.size))
        .collect::<Vec<_>>();
    out.sort_unstable();
    out
}
#[derive(Serialize)]
struct Timing {
    query: String,
    scope: String,
    hits: usize,
    p50_us: u128,
    p95_us: u128,
    key_comparisons: usize,
}
#[derive(Serialize)]
pub struct Row {
    dataset: String,
    entries: usize,
    distinct_names: usize,
    stored_name_slots: usize,
    layout: Layout,
    state: String,
    build_ms: u128,
    merge_ms: u128,
    snapshot_buffer_bytes: usize,
    delta_entries: usize,
    correctness_queries: usize,
    timings: Vec<Timing>,
}
pub fn run(sizes: &[usize]) -> Result<Vec<Row>> {
    let queries = queries();
    let mut report = vec![];
    for &n in sizes {
        for repeat in [true, false] {
            let rows = dataset(n, repeat);
            let distinct_names = rows
                .iter()
                .map(|r| r.name.as_str())
                .collect::<std::collections::HashSet<_>>()
                .len();
            let delta = mutations(&rows);
            let merged = logical(&rows, &delta);
            let expected_before = queries.iter().map(|q| oracle(&rows, q)).collect::<Vec<_>>();
            let expected_after = queries
                .iter()
                .map(|q| oracle(&merged, q))
                .collect::<Vec<_>>();
            for layout in [
                Layout::Columns,
                Layout::DirectoryColumns,
                Layout::DirectoryIntern,
                Layout::DirectoryInternBitmap,
            ] {
                let begin = Instant::now();
                let base = Snapshot::build(&rows, layout);
                let build_ms = begin.elapsed().as_millis();
                for (state, overlay, expected) in [
                    ("snapshot", HashMap::new(), &expected_before),
                    ("one_percent_delta", delta.clone(), &expected_after),
                ] {
                    let mut timings = vec![];
                    for (q, want) in queries.iter().zip(expected) {
                        let (got, comparisons) = base.search(q, &overlay);
                        ensure!(&got == want, "name mismatch {layout:?} {state} {}", q.label);
                        let mut times = vec![];
                        for _ in 0..7 {
                            let start = Instant::now();
                            let result = base.search(q, &overlay);
                            std::hint::black_box(&result);
                            times.push(start.elapsed().as_micros());
                        }
                        times.sort();
                        timings.push(Timing {
                            query: q.label.clone(),
                            scope: q.scope.clone(),
                            hits: got.len(),
                            p50_us: times[3],
                            p95_us: times[6],
                            key_comparisons: comparisons,
                        });
                    }
                    report.push(Row {
                        dataset: if repeat { "high_repetition" } else { "unique" }.into(),
                        entries: n,
                        distinct_names,
                        stored_name_slots: base.keys.len(),
                        layout,
                        state: state.into(),
                        build_ms,
                        merge_ms: 0,
                        snapshot_buffer_bytes: base.bytes(),
                        delta_entries: overlay.len(),
                        correctness_queries: queries.len(),
                        timings,
                    });
                }
                let begin = Instant::now();
                let after = Snapshot::build(&merged, layout);
                let merge_ms = begin.elapsed().as_millis();
                for (q, want) in queries.iter().zip(&expected_after) {
                    ensure!(
                        after.search(q, &HashMap::new()).0 == *want,
                        "merge lost results"
                    );
                }
                report.last_mut().unwrap().merge_ms = merge_ms;
            }
        }
    }
    Ok(report)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn layouts_overlay_and_merge_match_full_scan() {
        assert_eq!(run(&[160]).unwrap().len(), 16);
    }
    #[test]
    fn boundary_nfc_and_no_pinyin() {
        assert!(!in_scope("/Work/Archive", "/Work/A"));
        assert!(in_scope("/Work/A/x", "/Work/A"));
        assert!(Query::new("nfc", &["café"], "/").matches(&name_key("cafe\u{301}.txt")));
        assert!(!Query::new("literal", &["sj"], "/").matches(&name_key("数据.docx")));
    }
}
#[cfg(test)]
mod move_tests {
    use super::*;
    #[test]
    fn whole_subtree_move_hides_old_paths_and_merges() {
        let rows = dataset(1024, true);
        let mut delta = HashMap::new();
        for e in &rows {
            if in_scope(&e.dir, "/Work/A") {
                let mut moved = e.clone();
                moved.dir = moved.dir.replacen("/Work/A", "/Relocated", 1);
                delta.insert(e.id, Some(moved));
            }
        }
        let merged = logical(&rows, &delta);
        for layout in [
            Layout::Columns,
            Layout::DirectoryColumns,
            Layout::DirectoryIntern,
            Layout::DirectoryInternBitmap,
        ] {
            let base = Snapshot::build(&rows, layout);
            let packed = Snapshot::build(&merged, layout);
            for scope in ["/Work/A", "/Work/Archive", "/Relocated"] {
                let q = Query::new("move", &["数据"], scope);
                let expected = oracle(&merged, &q);
                assert_eq!(base.search(&q, &delta).0, expected);
                assert_eq!(packed.search(&q, &HashMap::new()).0, expected);
            }
        }
    }
}
