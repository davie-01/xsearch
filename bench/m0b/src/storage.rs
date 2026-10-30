//! Measures actual sync StoreReader cache misses, decoder input/output bytes and time.
use anyhow::{Result, ensure};
use serde::Serialize;
use std::{collections::BTreeMap, path::Path, time::Instant};
use tantivy::{
    Index, IndexSettings, ReloadPolicy, TantivyDocument,
    collector::DocSetCollector,
    query::AllQuery,
    schema::{STORED, Schema, Value},
    store::{Compressor, StoreReader},
};
use xs_core::{
    index::{Engine, GramKind},
    normalize::Mode,
    query::parse,
    validation::Document,
};
#[derive(Debug, Serialize, Default, Clone)]
pub struct Metrics {
    pub decoded_blocks: u64,
    pub compressed_decoder_input_bytes: u64,
    pub decompressed_block_bytes: u64,
    pub decode_ns: u64,
    pub block_cache_hits: u64,
}
impl Metrics {
    fn get() -> Self {
        let m = StoreReader::m0_metrics();
        Self {
            decoded_blocks: m[0],
            compressed_decoder_input_bytes: m[1],
            decompressed_block_bytes: m[2],
            decode_ns: m[3],
            block_cache_hits: m[4],
        }
    }
    fn add(&mut self, other: &Self) {
        self.decoded_blocks += other.decoded_blocks;
        self.compressed_decoder_input_bytes += other.compressed_decoder_input_bytes;
        self.decompressed_block_bytes += other.decompressed_block_bytes;
        self.decode_ns += other.decode_ns;
        self.block_cache_hits += other.block_cache_hits;
    }
}
fn dir_sizes(root: &Path) -> BTreeMap<String, u64> {
    let mut out = BTreeMap::new();
    for e in std::fs::read_dir(root).unwrap().flatten() {
        if e.path().is_file() {
            let kind = e
                .path()
                .extension()
                .and_then(|x| x.to_str())
                .unwrap_or("other")
                .to_string();
            *out.entry(kind).or_insert(0) += e.metadata().unwrap().len();
        }
    }
    out
}
fn percentile(times: &mut [u128]) -> (u128, u128) {
    times.sort_unstable();
    (
        times[(times.len() - 1) / 2],
        times[(times.len() * 95).div_ceil(100) - 1],
    )
}
#[derive(Serialize)]
pub struct StoreRow {
    dataset: String,
    compression: String,
    block_target: usize,
    cache_blocks: usize,
    cache_state: String,
    pattern: String,
    reads: usize,
    logical_text_bytes: usize,
    p50_ns: u128,
    p95_ns: u128,
    metrics: Metrics,
    index_files: BTreeMap<String, u64>,
}
fn synthetic() -> Vec<Document> {
    let mut out = vec![];
    let mut state = 0x745674u64;
    for i in 0..384 {
        let size = match i % 3 {
            0 => 1024,
            1 => 16 * 1024,
            _ => 128 * 1024,
        };
        let mut text = String::new();
        if i % 2 == 0 {
            while text.len() < size {
                text.push_str("数据共享 报告 日志 abcdefghijklmnopqrstuvwxyz 20261030\n");
            }
        } else {
            for _ in 0..size {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                text.push((32 + (state % 95) as u8) as char);
            }
        }
        out.push(Document {
            id: i as u64 + 1,
            name: format!("fixture-{i}"),
            text,
        });
    }
    out
}
pub fn stored_reads(root: &Path, real: &[Document]) -> Result<Vec<StoreRow>> {
    let synthetic = synthetic();
    let mut rows = vec![];
    for (label, docs) in [
        ("real-12", real),
        ("synthetic-mixed-sizes", synthetic.as_slice()),
    ] {
        for (compression, compressor, block_size) in [
            ("zstd", Compressor::Zstd(Default::default()), 16_384),
            ("zstd", Compressor::Zstd(Default::default()), 65_536),
            ("none", Compressor::None, 16_384),
        ] {
            let dir = root.join(format!("{label}-{compression}-{block_size}"));
            std::fs::create_dir_all(&dir)?;
            let mut schema = Schema::builder();
            let text = schema.add_text_field("text", STORED);
            let schema = schema.build();
            let settings = IndexSettings {
                docstore_compression: compressor,
                docstore_blocksize: block_size,
                ..Default::default()
            };
            let index = Index::builder()
                .schema(schema)
                .settings(settings)
                .create_in_dir(&dir)?;
            let mut writer = index.writer_with_num_threads(1, 30_000_000)?;
            writer.set_merge_policy(Box::new(tantivy::merge_policy::NoMergePolicy));
            for d in docs {
                let mut doc = TantivyDocument::default();
                doc.add_text(text, &d.text);
                writer.add_document(doc)?;
            }
            writer.commit()?;
            writer.wait_merging_threads()?;
            for cache in [0, 100] {
                for pattern in ["sequential", "shuffled", "hot_document"] {
                    let reader = index
                        .reader_builder()
                        .reload_policy(ReloadPolicy::Manual)
                        .doc_store_cache_num_blocks(cache)
                        .try_into()?;
                    let searcher: tantivy::Searcher = reader.searcher();
                    let mut addresses = searcher
                        .search(&AllQuery, &DocSetCollector)?
                        .into_iter()
                        .collect::<Vec<_>>();
                    addresses.sort_unstable();
                    if pattern == "shuffled" {
                        let mut seed = 991u64;
                        for i in (1..addresses.len()).rev() {
                            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                            addresses.swap(i, seed as usize % (i + 1));
                        }
                    }
                    if pattern == "hot_document" {
                        addresses = vec![addresses[addresses.len() / 2]; 128];
                    }
                    for pass in ["fresh_store_cache", "second_pass"] {
                        StoreReader::m0_reset_metrics();
                        let mut times = vec![];
                        let mut bytes = 0;
                        for a in &addresses {
                            let begin = Instant::now();
                            let d = searcher.doc::<TantivyDocument>(*a)?;
                            let value = d.get_first(text).and_then(|v| v.as_str()).unwrap();
                            bytes += value.len();
                            std::hint::black_box(value);
                            times.push(begin.elapsed().as_nanos());
                        }
                        let metrics = Metrics::get();
                        let (p50, p95) = percentile(&mut times);
                        rows.push(StoreRow {
                            dataset: label.into(),
                            compression: compression.into(),
                            block_target: block_size,
                            cache_blocks: cache,
                            cache_state: pass.into(),
                            pattern: pattern.into(),
                            reads: addresses.len(),
                            logical_text_bytes: bytes,
                            p50_ns: p50,
                            p95_ns: p95,
                            metrics,
                            index_files: dir_sizes(&dir),
                        });
                    }
                }
            }
        }
    }
    Ok(rows)
}
#[derive(Serialize)]
pub struct BloomRow {
    dataset: String,
    bloom: bool,
    cache_blocks: usize,
    cache_state: String,
    query: String,
    repeats: usize,
    hits: usize,
    candidates: usize,
    verified: usize,
    bloom_rejected: usize,
    p50_us: u128,
    p95_us: u128,
    metrics: Metrics,
    index_files: BTreeMap<String, u64>,
}
pub fn bloom_reads(root: &Path, real: &[Document]) -> Result<Vec<BloomRow>> {
    let terms = [
        "AI",
        "IP",
        "项目",
        "数据共享",
        "项目计划",
        "不存在的短语",
        "共享 -不存在",
        "AI | 共享",
    ];
    let adversarial = (0..512)
        .map(|i| Document {
            id: i + 1,
            name: format!("candidate-{i}"),
            text: if i % 32 == 0 {
                "abcdef target ".repeat(300)
            } else {
                "abc bcd cde def unconnected ".repeat(300)
            },
        })
        .collect::<Vec<_>>();
    let mut rows = vec![];
    for (label, docs, queries) in [
        ("real-12", real, terms.as_slice()),
        (
            "adversarial-trigram-false-positives",
            adversarial.as_slice(),
            ["abcdef", "abc -target", "abcdef | target"].as_slice(),
        ),
    ] {
        for enabled in [false, true] {
            let dir = root.join(format!("{label}-{enabled}"));
            let mut e = Engine::open(&dir, GramKind::Byte, enabled)?;
            e.writer
                .set_merge_policy(Box::new(tantivy::merge_policy::NoMergePolicy));
            for d in docs {
                e.put(d.id, 1, Some(&d.text))?;
            }
            e.commit("m0b")?;
            for cache in [0, 100] {
                for q in queries {
                    let expression = parse(q)?;
                    let mut expected = docs
                        .iter()
                        .filter(|d| expression.matches(&d.text, Mode::Loose))
                        .map(|d| d.id)
                        .collect::<Vec<_>>();
                    expected.sort();
                    e.reader = e
                        .index
                        .reader_builder()
                        .reload_policy(ReloadPolicy::Manual)
                        .doc_store_cache_num_blocks(cache)
                        .try_into()?;
                    for pass in ["fresh_store_cache", "warm_repeated"] {
                        let repeats = if pass == "fresh_store_cache" { 1 } else { 7 };
                        let mut times = vec![];
                        let mut metrics = Metrics::default();
                        let mut candidates = 0;
                        let mut verified = 0;
                        let mut rejected = 0;
                        for _ in 0..repeats {
                            StoreReader::m0_reset_metrics();
                            let begin = Instant::now();
                            let r = e.search(&expression, Mode::Loose, false)?;
                            times.push(begin.elapsed().as_micros());
                            let m = Metrics::get();
                            metrics.add(&m);
                            ensure!(r.ids == expected, "instrumented bloom recall mismatch {q}");
                            candidates += r.candidates;
                            verified += r.verified;
                            rejected += r.bloom_rejected;
                        }
                        let (p50, p95) = percentile(&mut times);
                        rows.push(BloomRow {
                            dataset: label.into(),
                            bloom: enabled,
                            cache_blocks: cache,
                            cache_state: pass.into(),
                            query: q.to_string(),
                            repeats,
                            hits: expected.len(),
                            candidates,
                            verified,
                            bloom_rejected: rejected,
                            p50_us: p50,
                            p95_us: p95,
                            metrics,
                            index_files: dir_sizes(&dir),
                        });
                    }
                }
            }
        }
    }
    Ok(rows)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn instrumentation_observes_cache_and_no_false_negatives() {
        let root = std::env::temp_dir().join(format!("xs-m0b-metrics-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let mut e = Engine::open(&root, GramKind::Byte, false).unwrap();
        e.put(1, 1, Some("hello 数据")).unwrap();
        e.commit("test").unwrap();
        e.reader = e
            .index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .doc_store_cache_num_blocks(100)
            .try_into()
            .unwrap();
        StoreReader::m0_reset_metrics();
        assert_eq!(
            e.search(&parse("数据").unwrap(), Mode::Loose, false)
                .unwrap()
                .ids,
            vec![1]
        );
        let first = Metrics::get();
        assert_eq!(first.decoded_blocks, 1);
        assert!(first.decompressed_block_bytes > 0);
        StoreReader::m0_reset_metrics();
        e.search(&parse("数据").unwrap(), Mode::Loose, false)
            .unwrap();
        let second = Metrics::get();
        assert_eq!(second.decoded_blocks, 0);
        assert_eq!(second.block_cache_hits, 1);
        drop(e);
        std::fs::remove_dir_all(root).unwrap();
    }
}
