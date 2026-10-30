use crate::{
    normalize::{Mode, NORM_VERSION, normalize},
    query::Expr,
};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    ops::Bound,
    path::Path,
    time::Instant,
};
use tantivy::{
    Index, IndexReader, IndexSettings, IndexWriter, ReloadPolicy, TantivyDocument, Term,
    collector::{Count, DocSetCollector},
    query::{AllQuery, BooleanQuery, Occur, Query, RangeQuery, TermQuery},
    schema::{FAST, Field, INDEXED, IndexRecordOption, STORED, STRING, Schema, Value},
};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum GramKind {
    Byte,
    Character,
}
#[derive(Clone)]
pub struct Fields {
    pub id: Field,
    pub seq: Field,
    pub live: Field,
    pub text: Field,
    pub gram: Field,
    pub bloom: Field,
    pub norm: Field,
}
pub struct Engine {
    pub index: Index,
    pub reader: IndexReader,
    pub writer: IndexWriter,
    pub fields: Fields,
    pub kind: GramKind,
    pub bloom_enabled: bool,
}
#[derive(Debug, Serialize)]
pub struct SearchResult {
    pub ids: Vec<u64>,
    pub candidates: usize,
    pub verified: usize,
    pub bloom_rejected: usize,
    pub text_bytes_read: usize,
    pub elapsed_us: u128,
}
pub fn byte_grams(text: &str) -> BTreeSet<u64> {
    let b = text.as_bytes();
    let mut g = b
        .windows(3)
        .map(|w| ((w[0] as u64) << 16) | ((w[1] as u64) << 8) | w[2] as u64)
        .collect::<BTreeSet<_>>();
    if b.len() >= 2 {
        g.insert((1 << 24) | ((b[b.len() - 2] as u64) << 8) | b[b.len() - 1] as u64);
    }
    g
}
fn char_grams(text: &str) -> BTreeSet<String> {
    let c = text.chars().collect::<Vec<_>>();
    (1..=3)
        .flat_map(|n| {
            c.windows(n)
                .map(|w| w.iter().collect::<String>())
                .collect::<Vec<_>>()
        })
        .collect()
}
fn hash(bytes: &[u8], seed: u64) -> u64 {
    bytes
        .iter()
        .fold(seed, |h, b| (h ^ (*b as u64)).wrapping_mul(0x100000001b3))
}
pub fn bloom(text: &str) -> Vec<u8> {
    let grams = text.as_bytes().windows(5).collect::<BTreeSet<_>>();
    let size = ((grams.len() * 8).div_ceil(8)).max(8);
    let mut out = vec![0u8; size];
    for g in grams {
        for seed in [0xcbf29ce484222325, 0x84222325cbf29ce4] {
            let bit = hash(g, seed) as usize % (size * 8);
            out[bit / 8] |= 1 << (bit % 8);
        }
    }
    out
}
pub fn bloom_pass(filter: &[u8], e: &Expr) -> bool {
    if filter.is_empty() {
        return true;
    }
    match e {
        Expr::Literal(s) => normalize(s, Mode::Loose)
            .text
            .as_bytes()
            .windows(5)
            .all(|g| {
                [0xcbf29ce484222325, 0x84222325cbf29ce4].iter().all(|seed| {
                    let b = hash(g, *seed) as usize % (filter.len() * 8);
                    filter[b / 8] & (1 << (b % 8)) != 0
                })
            }),
        Expr::And(xs) => xs.iter().all(|x| bloom_pass(filter, x)),
        Expr::Or(xs) => xs.iter().any(|x| bloom_pass(filter, x)),
        Expr::Not(_) => true,
    }
}
impl Engine {
    pub fn open(path: &Path, kind: GramKind, bloom_enabled: bool) -> Result<Self> {
        std::fs::create_dir_all(path)?;
        let mut b = Schema::builder();
        b.add_u64_field("file_id", INDEXED | FAST | STORED);
        b.add_u64_field("applied_seq", FAST | STORED);
        b.add_u64_field("live", INDEXED | FAST | STORED);
        b.add_text_field("display_text", STORED);
        match kind {
            GramKind::Byte => {
                b.add_u64_field("gram", INDEXED);
            }
            GramKind::Character => {
                b.add_text_field("gram", STRING);
            }
        }
        b.add_bytes_field("bloom", FAST);
        b.add_text_field("norm_ver", STRING | STORED);
        let schema = b.build();
        let index = if path.join("meta.json").exists() {
            Index::open_in_dir(path)?
        } else {
            let settings = IndexSettings {
                docstore_compression: tantivy::store::Compressor::Zstd(Default::default()),
                ..Default::default()
            };
            Index::builder()
                .schema(schema.clone())
                .settings(settings)
                .create_in_dir(path)?
        };
        let s = index.schema();
        anyhow::ensure!(
            s == schema,
            "incompatible index schema; rebuild with the requested gram layout"
        );
        let fields = Fields {
            id: s.get_field("file_id")?,
            seq: s.get_field("applied_seq")?,
            live: s.get_field("live")?,
            text: s.get_field("display_text")?,
            gram: s.get_field("gram")?,
            bloom: s.get_field("bloom")?,
            norm: s.get_field("norm_ver")?,
        };
        let writer = index.writer_with_num_threads(1, 30_000_000)?;
        let reader: IndexReader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;
        let incompatible = BooleanQuery::new(vec![
            (Occur::Must, Box::new(AllQuery)),
            (
                Occur::MustNot,
                Box::new(TermQuery::new(
                    Term::from_field_text(fields.norm, NORM_VERSION),
                    IndexRecordOption::Basic,
                )),
            ),
        ]);
        anyhow::ensure!(
            reader.searcher().search(&incompatible, &Count)? == 0,
            "normalization version changed; rebuild required"
        );
        Ok(Self {
            index,
            reader,
            writer,
            fields,
            kind,
            bloom_enabled,
        })
    }
    pub fn put(&mut self, id: u64, seq: u64, text: Option<&str>) -> Result<()> {
        let f = &self.fields;
        self.writer.delete_term(Term::from_field_u64(f.id, id));
        let mut d = TantivyDocument::default();
        d.add_u64(f.id, id);
        d.add_u64(f.seq, seq);
        d.add_u64(f.live, u64::from(text.is_some()));
        d.add_text(f.norm, NORM_VERSION);
        // Minimal tombstone preserves the delete fence across restart without retaining source text.
        if let Some(text) = text {
            d.add_text(f.text, text);
            let n = normalize(text, Mode::Loose).text;
            match self.kind {
                GramKind::Byte => {
                    for g in byte_grams(&n) {
                        d.add_u64(f.gram, g)
                    }
                }
                GramKind::Character => {
                    for g in char_grams(&n) {
                        d.add_text(f.gram, g)
                    }
                }
            }
            if self.bloom_enabled {
                d.add_bytes(f.bloom, &bloom(&n));
            }
        }
        self.writer.add_document(d)?;
        Ok(())
    }
    pub fn commit(&mut self, payload: &str) -> Result<()> {
        let mut c = self.writer.prepare_commit()?;
        c.set_payload(payload);
        c.commit()?;
        self.reader.reload()?;
        Ok(())
    }
    pub fn rollback(&mut self) -> Result<()> {
        self.writer.rollback()?;
        self.reader.reload()?;
        Ok(())
    }
    pub fn payload(&self) -> Result<Option<String>> {
        Ok(self.index.load_metas()?.payload)
    }
    pub fn applied(&self) -> Result<BTreeMap<u64, u64>> {
        let s = self.reader.searcher();
        let mut out = BTreeMap::new();
        for a in s.search(&AllQuery, &DocSetCollector)? {
            let d = s.doc::<TantivyDocument>(a)?;
            out.insert(
                d.get_first(self.fields.id)
                    .and_then(|v| v.as_u64())
                    .unwrap(),
                d.get_first(self.fields.seq)
                    .and_then(|v| v.as_u64())
                    .unwrap(),
            );
        }
        Ok(out)
    }
    fn term(&self, g: u64) -> Box<dyn Query> {
        Box::new(TermQuery::new(
            Term::from_field_u64(self.fields.gram, g),
            IndexRecordOption::Basic,
        ))
    }
    pub fn plan(&self, e: &Expr, pair_scan: bool) -> Box<dyn Query> {
        match e {
            Expr::Literal(t) => {
                let n = normalize(t, Mode::Loose).text;
                if self.kind == GramKind::Character {
                    let c = n.chars().collect::<Vec<_>>();
                    if c.is_empty() {
                        return Box::new(AllQuery);
                    }
                    let k = c.len().min(3);
                    return Box::new(BooleanQuery::intersection(
                        c.windows(k)
                            .map(|w| {
                                Box::new(TermQuery::new(
                                    Term::from_field_text(
                                        self.fields.gram,
                                        &w.iter().collect::<String>(),
                                    ),
                                    IndexRecordOption::Basic,
                                )) as Box<dyn Query>
                            })
                            .collect(),
                    ));
                }
                let b = n.as_bytes();
                match b.len() {
                    0 | 1 => Box::new(AllQuery),
                    2 if pair_scan => Box::new(AllQuery),
                    2 => {
                        let pair = ((b[0] as u64) << 8) | b[1] as u64;
                        Box::new(BooleanQuery::union(vec![
                            Box::new(RangeQuery::new(
                                Bound::Included(Term::from_field_u64(self.fields.gram, pair << 8)),
                                Bound::Included(Term::from_field_u64(
                                    self.fields.gram,
                                    (pair << 8) | 255,
                                )),
                            )),
                            self.term((1 << 24) | pair),
                        ]))
                    }
                    _ => Box::new(BooleanQuery::intersection(
                        b.windows(3)
                            .map(|w| {
                                self.term(
                                    ((w[0] as u64) << 16) | ((w[1] as u64) << 8) | w[2] as u64,
                                )
                            })
                            .collect(),
                    )),
                }
            }
            Expr::And(xs) => Box::new(BooleanQuery::intersection(
                xs.iter().map(|x| self.plan(x, pair_scan)).collect(),
            )),
            Expr::Or(xs) => Box::new(BooleanQuery::union(
                xs.iter().map(|x| self.plan(x, pair_scan)).collect(),
            )),
            Expr::Not(_) => Box::new(AllQuery),
        }
    }
    pub fn search(&self, e: &Expr, mode: Mode, pair_scan: bool) -> Result<SearchResult> {
        let start = Instant::now();
        let s = self.reader.searcher();
        let q = BooleanQuery::new(vec![
            (Occur::Must, self.plan(e, pair_scan)),
            (
                Occur::Must,
                Box::new(TermQuery::new(
                    Term::from_field_u64(self.fields.live, 1),
                    IndexRecordOption::Basic,
                )),
            ),
        ]);
        let mut addresses = s
            .search(&q, &DocSetCollector)?
            .into_iter()
            .collect::<Vec<_>>();
        addresses.sort();
        let mut r = SearchResult {
            ids: vec![],
            candidates: addresses.len(),
            verified: 0,
            bloom_rejected: 0,
            text_bytes_read: 0,
            elapsed_us: 0,
        };
        for a in addresses {
            if self.bloom_enabled {
                let segment = s.segment_reader(a.segment_ord);
                if let Some(col) = segment.fast_fields().bytes("bloom")?
                    && let Some(ord) = col.term_ords(a.doc_id).next()
                {
                    let mut bytes = vec![];
                    if col.ord_to_bytes(ord, &mut bytes)? && !bloom_pass(&bytes, e) {
                        r.bloom_rejected += 1;
                        continue;
                    }
                }
            }
            let d = s.doc::<TantivyDocument>(a)?;
            anyhow::ensure!(
                d.get_first(self.fields.norm).and_then(|v| v.as_str()) == Some(NORM_VERSION),
                "normalization version changed; rebuild required"
            );
            let text = d
                .get_first(self.fields.text)
                .and_then(|v| v.as_str())
                .unwrap_or("");
            r.verified += 1;
            r.text_bytes_read += text.len();
            if e.matches(text, mode) {
                r.ids.push(
                    d.get_first(self.fields.id)
                        .and_then(|v| v.as_u64())
                        .unwrap(),
                );
            }
        }
        r.ids.sort_unstable();
        r.elapsed_us = start.elapsed().as_micros();
        Ok(r)
    }
}
