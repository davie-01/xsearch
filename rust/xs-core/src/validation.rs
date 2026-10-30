//! Reproducible correctness and bounded warm-cache benchmark harness, not production search UI.
use crate::{
    index::{Engine, GramKind},
    normalize::{Mode, normalize},
    query::{Expr, can_narrow, name_matches, parse},
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::{path::Path, time::Instant};
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    pub id: u64,
    pub name: String,
    pub text: String,
}
#[derive(Serialize)]
pub struct Validation {
    pub documents: usize,
    pub expressions: usize,
    pub comparisons: usize,
    pub mismatches: usize,
    pub normalization_substrings: usize,
    pub narrowing_cases: usize,
}
pub fn corpus() -> Vec<Document> {
    let seeds = [
        "合同书 数据共享 AI IP",
        "cafe\u{301} café ﬁ Straße İ ＡＢＣ",
        "alpha beta gamma",
        "abc bc ab a",
        "😀𠀀甲乙丙",
        "a\t\n b",
        "각 각",
        "a\u{315}\u{300}",
        "",
        "ab",
        "cab",
        "ba",
        "No contract",
        "aaa aaaa",
        "Budget 2026/10/29",
        "数据库共享 数据分隔共享",
    ];
    let mut docs = seeds
        .iter()
        .enumerate()
        .map(|(i, t)| Document {
            id: i as u64 + 1,
            name: format!("{t}.txt"),
            text: t.to_string(),
        })
        .collect::<Vec<_>>();
    let alphabet = [
        'a', 'b', 'C', 'é', '\u{301}', '中', '😀', ' ', '\t', 'ß', 'ﬁ', '\u{315}', '\u{300}',
    ];
    let mut state = 0x5035u64;
    for i in 0..80 {
        let text = (0..24)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                alphabet[state as usize % alphabet.len()]
            })
            .collect();
        docs.push(Document {
            id: 100 + i,
            name: format!("fixture-{i}.txt"),
            text,
        });
    }
    docs
}
pub fn expressions(docs: &[Document]) -> Vec<Expr> {
    let mut terms = vec![
        "a",
        "ab",
        "ba",
        "AI",
        "IP",
        "合同",
        "合同书",
        "共享",
        "cafe",
        "café",
        "ﬁ",
        "fi",
        "straße",
        "ss",
        "İ",
        "😀",
        "𠀀",
        "不存在",
        " ",
        "\t",
        "\u{301}",
        "a\u{315}\u{300}",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect::<Vec<_>>();
    for d in docs.iter().take(100) {
        let c = d.text.chars().collect::<Vec<_>>();
        for start in 0..c.len().min(8) {
            for len in 1..=3 {
                if start + len <= c.len() {
                    terms.push(c[start..start + len].iter().collect())
                }
            }
        }
    }
    terms.sort();
    terms.dedup();
    let mut out = terms.into_iter().map(Expr::Literal).collect::<Vec<_>>();
    for s in [
        "a b",
        "ab | AI",
        "-合同",
        "合同 -书",
        "AI | 合同 -不存在",
        "-(a | b)",
        "(ab | 合同) -不存在",
        "a -b | 共享",
        "-a -b",
        "cafe\u{301} | AI",
        "\"a b\" | ﬁ",
    ] {
        out.push(parse(s).unwrap());
    }
    out
}
pub fn verify(root: &Path, extra: &[Document]) -> Result<Validation> {
    let mut docs = corpus();
    for (i, d) in extra.iter().enumerate() {
        let mut d = d.clone();
        d.id = 10_000 + i as u64;
        docs.push(d)
    }
    let exprs = expressions(&docs);
    let mut comparisons = 0;
    for (name, kind, bloom) in [
        ("byte", GramKind::Byte, false),
        ("byte-bloom", GramKind::Byte, true),
        ("character", GramKind::Character, false),
    ] {
        let mut engine = Engine::open(&root.join(name), kind, bloom)?;
        for d in &docs {
            engine.put(d.id, 1, Some(&d.text))?;
        }
        engine.commit("validation")?;
        for e in &exprs {
            for mode in Mode::ALL {
                let mut expected = docs
                    .iter()
                    .filter(|d| e.matches(&d.text, mode))
                    .map(|d| d.id)
                    .collect::<Vec<_>>();
                expected.sort();
                for scan in [false, true] {
                    let got = engine.search(e, mode, scan)?;
                    ensure!(
                        got.ids == expected,
                        "recall mismatch: {name} {mode:?} {e:?}, expected {expected:?} got {:?}",
                        got.ids
                    );
                    comparisons += 1;
                }
            }
        }
    }
    let mut substrings = 0;
    for d in corpus().iter().take(40) {
        let c = d.text.chars().collect::<Vec<_>>();
        let n = normalize(&d.text, Mode::Loose).text;
        for a in 0..c.len() {
            for b in a + 1..=c.len() {
                let sub = c[a..b].iter().collect::<String>();
                ensure!(
                    n.contains(&normalize(&sub, Mode::Loose).text),
                    "substring invariant"
                );
                substrings += 1;
            }
        }
    }
    let names = [
        "cafe.txt",
        "café.txt",
        "cafe\u{301}.txt",
        "合同.txt",
        "合同书.txt",
        "发票.txt",
        "alpha beta.txt",
        "ALPHABET.txt",
        "Straße.txt",
    ];
    let mut narrow = 0;
    for (a, b) in [
        ("cafe", "cafe\u{301}"),
        ("合同", "合同书"),
        ("合同", "合同 书"),
        ("-合同", "-合同书"),
        ("合同", "合同 | 发票"),
        ("alpha", "alphab"),
        ("alpha", "alpha beta"),
        ("s", "str"),
        ("合同书", "合同"),
    ] {
        let (a, b) = (parse(a)?, parse(b)?);
        if can_narrow(&a, &b) {
            let previous = names
                .iter()
                .filter(|n| name_matches(&a, n))
                .collect::<Vec<_>>();
            let narrowed = previous
                .into_iter()
                .filter(|n| name_matches(&b, n))
                .collect::<Vec<_>>();
            let full = names
                .iter()
                .filter(|n| name_matches(&b, n))
                .collect::<Vec<_>>();
            ensure!(narrowed == full, "unsafe name narrowing");
        }
        narrow += 1;
    }
    ensure!(
        !can_narrow(&parse("cafe")?, &parse("cafe\u{301}")?),
        "NFC extension must rerun"
    );
    Ok(Validation {
        documents: docs.len(),
        expressions: exprs.len(),
        comparisons,
        mismatches: 0,
        normalization_substrings: substrings,
        narrowing_cases: narrow,
    })
}
fn tree_bytes(p: &Path) -> u64 {
    std::fs::read_dir(p)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| {
            if e.path().is_dir() {
                tree_bytes(&e.path())
            } else {
                e.metadata().map(|m| m.len()).unwrap_or(0)
            }
        })
        .sum()
}
#[derive(Serialize)]
pub struct Benchmark {
    pub variant: String,
    pub documents: usize,
    pub source_utf8_bytes: usize,
    pub index_bytes: u64,
    pub build_ms: u128,
    pub queries: usize,
    pub p50_us: u128,
    pub p95_us: u128,
    pub candidates: usize,
    pub verified: usize,
    pub bloom_rejected: usize,
    pub logical_text_bytes_read: usize,
}
pub fn benchmark(root: &Path, docs: &[Document]) -> Result<Vec<Benchmark>> {
    let expressions = [
        "AI",
        "IP",
        "合同",
        "数据共享",
        "项目计划",
        "不存在的短语",
        "cafe",
        "a",
        "共享 -不存在",
        "AI | 共享",
    ]
    .iter()
    .map(|q| parse(q).unwrap())
    .collect::<Vec<_>>();
    let mut rows = vec![];
    for (name, kind, bloom, scan) in [
        ("byte-baseline", GramKind::Byte, false, false),
        ("byte-pair-scan", GramKind::Byte, false, true),
        ("byte-bloom", GramKind::Byte, true, false),
        ("character", GramKind::Character, false, false),
    ] {
        let dir = root.join(name);
        let start = Instant::now();
        let mut e = Engine::open(&dir, kind, bloom)?;
        for d in docs {
            e.put(d.id, 1, Some(&d.text))?;
        }
        e.commit("benchmark")?;
        let build_ms = start.elapsed().as_millis();
        for q in &expressions {
            e.search(q, Mode::Loose, scan)?;
        }
        let mut row = Benchmark {
            variant: name.into(),
            documents: docs.len(),
            source_utf8_bytes: docs.iter().map(|d| d.text.len()).sum(),
            index_bytes: tree_bytes(&dir),
            build_ms,
            queries: 100,
            p50_us: 0,
            p95_us: 0,
            candidates: 0,
            verified: 0,
            bloom_rejected: 0,
            logical_text_bytes_read: 0,
        };
        let mut times = vec![];
        for _ in 0..10 {
            for q in &expressions {
                let r = e.search(q, Mode::Loose, scan)?;
                times.push(r.elapsed_us);
                row.candidates += r.candidates;
                row.verified += r.verified;
                row.bloom_rejected += r.bloom_rejected;
                row.logical_text_bytes_read += r.text_bytes_read;
            }
        }
        times.sort();
        row.p50_us = times[49];
        row.p95_us = times[94];
        rows.push(row);
    }
    Ok(rows)
}
