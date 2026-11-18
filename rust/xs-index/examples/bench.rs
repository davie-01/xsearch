//! Content-query latency baseline (ARCHITECTURE §19): first verified screen and full completion.
//! `cargo run --release -p xs-index --example bench -- OUT_DIR [N_SYNTHETIC] [REAL_CORPUS.json]`
//! Output is JSON on stdout; the index directory must be fresh.
use std::{
    sync::atomic::AtomicBool,
    time::{Duration, Instant},
};
use xs_index::{ContentDoc, ContentReader, ContentWriter, Mode, SearchRequest, parse};

#[derive(serde::Deserialize)]
struct RealDoc {
    id: u64,
    name: String,
    text: String,
}

fn synthetic(n: usize) -> Vec<ContentDoc> {
    let zh = [
        "合同", "数据", "共享", "方案", "项目", "建设", "智慧", "城市", "实施", "管理", "系统",
        "平台", "服务", "安全", "网络", "资金", "预算", "审批", "报告", "附件", "第", "的", "和",
        "在", "是", "对", "按", "年", "月", "日",
    ];
    let en = [
        "report", "budget", "contract", "network", "platform", "service", "data", "sharing", "AI",
        "IP", "cloud", "storage", "invoice", "the", "and", "of",
    ];
    let mut x = 0x1234_5678u64;
    let mut rnd = move |m: usize| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        (x as usize) % m
    };
    (0..n)
        .map(|i| {
            let words = 600 + rnd(1800);
            let mut t = String::with_capacity(words * 4);
            for w in 0..words {
                // Zipf-ish: low indexes much more frequent.
                let r = rnd(1000);
                let k = (r * r) / 1000;
                if rnd(5) == 0 {
                    t.push_str(en[k * en.len() / 1000]);
                    t.push(' ');
                } else {
                    t.push_str(zh[k * zh.len() / 1000]);
                }
                if w % 23 == 0 {
                    t.push_str(&format!("{}，", 2000 + rnd(30)));
                }
                if w % 61 == 0 {
                    t.push('\n');
                }
            }
            ContentDoc {
                file_id: i as u64 + 1,
                op_seq: 1,
                revision: 1,
                extractor_ver: 1,
                scope_ids: vec![1],
                dir: format!("/Users/t/Docs/{}", ["A", "B", "Archive", "下载"][i % 4]),
                name: format!("doc-{i}.docx"),
                size: t.len() as i64,
                mtime: i as i64,
                text: t,
                ..Default::default()
            }
        })
        .collect()
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() - 1) as f64 * p).round() as usize]
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let out = std::path::PathBuf::from(&args[1]);
    anyhow::ensure!(!out.exists(), "use a fresh output directory");
    let n: usize = args
        .get(2)
        .map(|s| s.parse())
        .transpose()?
        .unwrap_or(20_000);
    let mut sets: Vec<(String, Vec<ContentDoc>)> = vec![("synthetic".into(), synthetic(n))];
    if let Some(p) = args.get(3) {
        let real: Vec<RealDoc> = serde_json::from_slice(&std::fs::read(p)?)?;
        sets.push((
            "real".into(),
            real.into_iter()
                .map(|d| ContentDoc {
                    file_id: d.id,
                    op_seq: 1,
                    scope_ids: vec![1],
                    dir: "/real".into(),
                    name: d.name,
                    size: d.text.len() as i64,
                    mtime: d.id as i64,
                    text: d.text,
                    ..Default::default()
                })
                .collect(),
        ));
    }
    let queries = [
        "数",
        "数据",
        "数据共",
        "共享方案",
        "port",
        "ud",
        "2015",
        "，",
        "的",
        "合同 -附件",
        "AI | IP",
        "智慧 城市 2020",
        "dir:/Users/t/Docs/A 合同",
        "不存在的词组",
    ];
    let mut report = vec![];
    for (label, docs) in sets {
        let dir = out.join(&label);
        let bytes: usize = docs.iter().map(|d| d.text.len()).sum();
        let t0 = Instant::now();
        let mut w = ContentWriter::open(&dir, "bench")?;
        for d in &docs {
            w.put(d)?;
        }
        w.commit(1)?;
        let build_ms = t0.elapsed().as_millis();
        drop(w);
        let size: u64 = std::fs::read_dir(&dir)?
            .filter_map(|e| e.ok()?.metadata().ok())
            .map(|m| m.len())
            .sum();
        let reader = ContentReader::open(&dir)?;
        let cancel = AtomicBool::new(false);
        let mut rows = vec![];
        for q in queries {
            let (dirs, text) = match q.strip_prefix("dir:") {
                Some(r) => {
                    let (d, t) = r.split_once(' ').unwrap();
                    (vec![d.to_string()], t)
                }
                None => (vec![], q),
            };
            let req = SearchRequest {
                expr: parse(text)?,
                mode: Mode::Loose,
                dirs,
                exts: vec![],
                scopes: vec![], size: None, mtime: None, names: vec![]
            };
            let (mut first, mut full) = (vec![], vec![]);
            let (mut hits, mut candidates, mut recall) = (0, 0, String::new());
            for rep in 0..8 {
                let t = Instant::now();
                let mut s = reader.session(req.clone())?;
                recall = format!("{:?}", s.recall);
                let b = s.next(Duration::from_millis(30), 20, &cancel)?;
                let f = t.elapsed().as_secs_f64() * 1000.0;
                let mut total = b.hits.len();
                let mut done = b.done;
                while !done {
                    let b = s.next(Duration::from_secs(60), usize::MAX, &cancel)?;
                    total += b.hits.len();
                    done = b.done;
                }
                if rep > 0 {
                    first.push(f);
                    full.push(t.elapsed().as_secs_f64() * 1000.0);
                }
                hits = total;
                candidates = s.candidates();
            }
            rows.push(serde_json::json!({"query": q, "recall": recall, "candidates": candidates, "hits": hits,
                "first_p50_ms": pct(&mut first, 0.5), "first_p95_ms": pct(&mut first, 0.95), "full_p50_ms": pct(&mut full, 0.5), "full_p95_ms": pct(&mut full, 0.95)}));
        }
        report.push(serde_json::json!({"corpus": label, "documents": docs.len(), "text_bytes": bytes, "index_bytes": size, "build_ms": build_ms, "queries": rows}));
    }
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}
