use std::{
    collections::BTreeSet,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
use xs_core::{
    normalize::normalize_text,
    validation::{corpus, expressions},
};
use xs_index::{
    ContentDoc, ContentReader, ContentWriter, Expr, Mode, Recall, SearchRequest, parse,
};

const DIRS: [&str; 4] = ["/Work/A", "/Work/A/B", "/Work/Archive", "/Users/t/下载"];
const EXTS: [&str; 3] = ["txt", "docx", "PDF"];

fn doc(id: u64, text: &str) -> ContentDoc {
    let i = id as usize;
    ContentDoc {
        file_id: id,
        op_seq: 1,
        revision: 1,
        extractor_ver: 1,
        scope_ids: vec![(id % 2) + 1],
        dir: DIRS[i % DIRS.len()].into(),
        name: format!("file-{id}.{}", EXTS[i % EXTS.len()]),
        size: text.len() as i64,
        mtime: (id * 7919 % 1000) as i64,
        text: text.into(),
        ..Default::default()
    }
}

fn run_all(reader: &ContentReader, req: SearchRequest) -> (BTreeSet<u64>, Recall, usize) {
    let mut s = reader.session(req).unwrap();
    let recall = s.recall;
    let cancel = AtomicBool::new(false);
    let mut ids = BTreeSet::new();
    let mut batches = 0;
    loop {
        let b = s.next(Duration::from_secs(5), usize::MAX, &cancel).unwrap();
        batches += 1;
        for h in b.hits {
            assert!(ids.insert(h.file_id), "duplicate hit {}", h.file_id);
        }
        if b.done {
            break;
        }
    }
    (ids, recall, batches)
}

fn in_dir(dir: &str, filter: &str) -> bool {
    let d = dir.to_lowercase();
    let f = filter.to_lowercase();
    f == "/" || d == f || d.starts_with(&(f + "/"))
}

#[test]
fn matches_brute_force_in_all_modes_with_filters() {
    let tmp = tempfile::tempdir().unwrap();
    let docs = corpus();
    let mut w = ContentWriter::open(tmp.path(), "inst-a").unwrap();
    for d in &docs {
        w.put(&doc(d.id, &d.text)).unwrap();
    }
    w.commit(1).unwrap();
    let reader = ContentReader::open(tmp.path()).unwrap();
    let exprs = expressions(&docs);
    let filters: Vec<(Vec<String>, Vec<String>, Vec<u64>)> = vec![
        (vec![], vec![], vec![]),
        (vec!["/Work/A".into()], vec![], vec![]),
        (
            vec!["/work/a/b".into(), "/Users/t/下载".into()],
            vec!["TXT".into()],
            vec![],
        ),
        (vec![], vec!["pdf".into(), ".docx".into()], vec![2]),
    ];
    let mut comparisons = 0;
    for e in &exprs {
        for mode in Mode::ALL {
            for (dirs, exts, scopes) in &filters {
                let want: BTreeSet<u64> = docs
                    .iter()
                    .filter(|d| {
                        let cd = doc(d.id, &d.text);
                        e.matches(&d.text, mode)
                            && (dirs.is_empty() || dirs.iter().any(|f| in_dir(&cd.dir, f)))
                            && (exts.is_empty()
                                || exts.iter().any(|x| {
                                    cd.name.to_lowercase().ends_with(&format!(
                                        ".{}",
                                        x.trim_start_matches('.').to_lowercase()
                                    ))
                                }))
                            && (scopes.is_empty()
                                || scopes.iter().any(|s| cd.scope_ids.contains(s)))
                    })
                    .map(|d| d.id)
                    .collect();
                let req = SearchRequest {
                    expr: e.clone(),
                    mode,
                    dirs: dirs.clone(),
                    exts: exts.clone(),
                    scopes: scopes.clone(), size: None, mtime: None
                };
                let (got, _, _) = run_all(&reader, req);
                assert_eq!(got, want, "{e:?} {mode:?} {dirs:?} {exts:?} {scopes:?}");
                comparisons += 1;
            }
        }
    }
    assert!(comparisons > 3000, "{comparisons}");
}

#[test]
fn recall_kinds_explain_cost() {
    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "i").unwrap();
    w.put(&doc(1, "合同书 abc")).unwrap();
    w.commit(1).unwrap();
    let r = ContentReader::open(tmp.path()).unwrap();
    let kind = |q: &str| {
        r.session(SearchRequest {
            expr: parse(q).unwrap(),
            mode: Mode::Loose,
            dirs: vec![],
            exts: vec![],
            scopes: vec![], size: None, mtime: None
        })
        .unwrap()
        .recall
    };
    assert_eq!(kind("abc"), Recall::Trigram);
    assert_eq!(kind("合"), Recall::Trigram); // 3 UTF-8 bytes
    assert_eq!(kind("ab"), Recall::Pair);
    assert_eq!(kind("a"), Recall::Scan);
    assert_eq!(kind("-abc"), Recall::Scan);
    assert_eq!(kind("abc a"), Recall::LongTermsThenVerify);
    assert_eq!(kind("abc | a"), Recall::Scan);
}

#[test]
fn progressive_batches_cancel_and_completeness() {
    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "i").unwrap();
    for id in 1..=3000u64 {
        let text = if id % 3 == 0 {
            format!("第 {id} 份 合同 内容 alpha")
        } else {
            format!("文档 {id} beta")
        };
        w.put(&doc(id, &text)).unwrap();
    }
    w.commit(1).unwrap();
    let r = ContentReader::open(tmp.path()).unwrap();
    let req = SearchRequest {
        expr: parse("a").unwrap(),
        mode: Mode::Loose,
        dirs: vec![],
        exts: vec![],
        scopes: vec![], size: None, mtime: None
    };
    // Tiny budget: many batches, each making progress, union equals the full answer.
    let mut s = r.session(req.clone()).unwrap();
    assert_eq!(s.recall, Recall::Scan);
    let cancel = AtomicBool::new(false);
    let mut ids = BTreeSet::new();
    let mut batches = 0;
    let mut last_verified = 0;
    loop {
        let b = s.next(Duration::ZERO, 10, &cancel).unwrap();
        assert!(b.verified > last_verified, "every call makes progress");
        last_verified = b.verified;
        batches += 1;
        ids.extend(b.hits.iter().map(|h| h.file_id));
        if b.done {
            break;
        }
    }
    assert!(batches > 100);
    let (all, _, _) = run_all(&r, req.clone());
    assert_eq!(ids, all);
    assert_eq!(all.len(), 3000); // "alpha"/"beta" both contain "a"
    // Cancellation stops immediately and leaves the session resumable.
    let mut s = r.session(req).unwrap();
    cancel.store(true, Ordering::Relaxed);
    let b = s.next(Duration::from_secs(1), usize::MAX, &cancel).unwrap();
    assert!(b.hits.is_empty() && !b.done && b.verified == 0);
    // Newest first.
    cancel.store(false, Ordering::Relaxed);
    let b = s.next(Duration::from_secs(1), 5, &cancel).unwrap();
    assert!(b.hits.windows(2).all(|w| w[0].mtime >= w[1].mtime));
}

#[test]
fn updates_tombstones_and_restart() {
    let tmp = tempfile::tempdir().unwrap();
    {
        let mut w = ContentWriter::open(tmp.path(), "inst-1").unwrap();
        w.put(&doc(1, "原始 合同")).unwrap();
        w.put(&doc(2, "将被删除 合同")).unwrap();
        w.commit(7).unwrap();
        let mut d = doc(1, "修改后 发票");
        d.op_seq = 5;
        w.put(&d).unwrap();
        w.remove(2, 9).unwrap();
        // Staged but rolled back: invisible and not persisted.
        w.put(&doc(3, "回滚 合同")).unwrap();
        w.rollback().unwrap();
        w.put(&d).unwrap();
        w.remove(2, 9).unwrap();
        w.commit(8).unwrap();
    }
    let w = ContentWriter::open(tmp.path(), "ignored-for-existing").unwrap();
    assert_eq!(w.instance_id, "inst-1");
    assert_eq!(w.last_commit().unwrap().map(|c| c.batch_id), Some(8));
    let seqs = w.applied_seqs().unwrap();
    assert_eq!(seqs.get(&1), Some(&5));
    assert_eq!(seqs.get(&2), Some(&9), "tombstone keeps the sequence fence");
    assert_eq!(seqs.get(&3), None);
    assert_eq!(w.committed_text(2).unwrap(), None);
    let r = ContentReader::open(tmp.path()).unwrap();
    assert_eq!(r.live_count().unwrap(), 1);
    let q = |s: &str| {
        run_all(
            &r,
            SearchRequest {
                expr: parse(s).unwrap(),
                mode: Mode::Loose,
                dirs: vec![],
                exts: vec![],
                scopes: vec![], size: None, mtime: None
            },
        )
        .0
    };
    assert!(q("合同").is_empty());
    assert_eq!(q("发票"), BTreeSet::from([1]));
    assert!(r.document(2).unwrap().is_none());
    assert_eq!(r.document(1).unwrap().unwrap().text, "修改后 发票");
}

#[test]
fn snippets_and_highlights_point_at_hits() {
    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "i").unwrap();
    let long = format!(
        "{}关于数据共享方案的说明😀 数据共享 结束{}",
        "前言".repeat(20),
        "附录".repeat(30)
    );
    w.put(&doc(1, &long)).unwrap();
    w.put(&doc(2, "Straße und STRASSE\n\n\tcafe\u{301} Café"))
        .unwrap();
    w.commit(1).unwrap();
    let r = ContentReader::open(tmp.path()).unwrap();
    let mut s = r
        .session(SearchRequest {
            expr: parse("数据共享").unwrap(),
            mode: Mode::Loose,
            dirs: vec![],
            exts: vec![],
            scopes: vec![], size: None, mtime: None
        })
        .unwrap();
    let h = s
        .next(Duration::from_secs(1), 10, &AtomicBool::new(false))
        .unwrap()
        .hits
        .remove(0);
    assert_eq!(h.hit_count, 2);
    assert!(
        h.snippet.starts_with('…') && h.snippet.ends_with('…'),
        "{}",
        h.snippet
    );
    let u16: Vec<u16> = h.snippet.encode_utf16().collect();
    for r in &h.snippet_highlights {
        assert_eq!(
            String::from_utf16(&u16[r.start as usize..r.end as usize]).unwrap(),
            "数据共享"
        );
    }
    // Preview highlights: UTF-16 ranges over the full text, past the emoji (2 code units).
    let text: Vec<u16> = long.encode_utf16().collect();
    let hl = r
        .highlights(1, &parse("数据共享").unwrap(), Mode::Loose)
        .unwrap();
    assert_eq!(hl.len(), 2);
    for x in &hl {
        assert_eq!(
            String::from_utf16(&text[x.start as usize..x.end as usize]).unwrap(),
            "数据共享"
        );
    }
    // Loose: ß ~ ss, composed ~ decomposed, highlights map back to source characters.
    let doc2: Vec<u16> = "Straße und STRASSE\n\n\tcafe\u{301} Café"
        .encode_utf16()
        .collect();
    let hl = r
        .highlights(2, &parse("strasse | café").unwrap(), Mode::Loose)
        .unwrap();
    let found: Vec<String> = hl
        .iter()
        .map(|x| String::from_utf16(&doc2[x.start as usize..x.end as usize]).unwrap())
        .collect();
    assert_eq!(found, vec!["Straße", "STRASSE", "cafe\u{301}", "Café"]);
    for f in &found {
        let n = normalize_text(f, Mode::Loose);
        assert!(
            ["strasse", "café"]
                .iter()
                .any(|q| normalize_text(q, Mode::Loose) == n),
            "{f:?}"
        );
    }
    // Strict: exact scalars only.
    let hl = r
        .highlights(2, &Expr::Literal("Café".into()), Mode::Strict)
        .unwrap();
    assert_eq!(hl.len(), 1);
}

#[test]
fn refuses_foreign_or_missing_index() {
    let tmp = tempfile::tempdir().unwrap();
    assert!(ContentReader::open(tmp.path()).is_err());
    ContentWriter::open(tmp.path(), "i")
        .unwrap()
        .commit(1)
        .unwrap();
    let side = tmp.path().join("xsearch-index.json");
    let text = std::fs::read_to_string(&side)
        .unwrap()
        .replace("xs-content-v1", "xs-content-v0");
    std::fs::write(&side, text).unwrap();
    let err = ContentReader::open(tmp.path()).err().unwrap().to_string();
    assert!(err.contains("rebuild"), "{err}");
}

#[test]
fn proximity_and_regex() {
    use xs_core::query::{near_match, required_literal};
    assert_eq!(
        parse(r#""合同 金额"~5 -草稿"#).unwrap(),
        Expr::And(vec![
            Expr::Near { terms: vec!["合同".into(), "金额".into()], slop: 5 },
            Expr::Not(Box::new(Expr::Literal("草稿".into()))),
        ])
    );
    // A single word or a missing number stays a plain quoted literal.
    assert_eq!(parse(r#""合同"~5"#).unwrap(), Expr::And(vec![Expr::Literal("合同".into()), Expr::Literal("~5".into())]));
    assert_eq!(parse(r"regex:(a|b)\d+ x").unwrap(), Expr::And(vec![Expr::Regex(r"(a|b)\d+".into()), Expr::Literal("x".into())]));
    assert!(parse("regex:(").is_err() && parse("regex:").is_err());
    assert_eq!(required_literal(r"合同编号\d{4}"), Some("合同编号".into()));
    assert_eq!(required_literal(r"(foo|bar)\d"), None);
    assert!(near_match("合同的总金额", &["金额".into(), "合同".into()], 2));
    assert!(!near_match("合同的总金额", &["金额".into(), "合同".into()], 1));
    assert!(near_match("金额 xx 合同", &["合同".into(), "金额".into()], 4));

    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "inst-a").unwrap();
    let texts = ["合同金额为 100 万元", "合同正文……很长的一段话……最后写金额", "编号 HT-2024-0031 的合同", "编号 HT-24 草稿"];
    for (i, t) in texts.iter().enumerate() {
        w.put(&doc(i as u64 + 1, t)).unwrap();
    }
    w.commit(1).unwrap();
    let reader = ContentReader::open(tmp.path()).unwrap();
    let req = |q: &str| SearchRequest { expr: parse(q).unwrap(), mode: Mode::Loose, dirs: vec![], exts: vec![], scopes: vec![], size: None, mtime: None };
    assert_eq!(run_all(&reader, req(r#""合同 金额"~3"#)).0, BTreeSet::from([1]));
    assert_eq!(run_all(&reader, req(r#""合同 金额"~30"#)).0, BTreeSet::from([1, 2]));
    let (ids, recall, _) = run_all(&reader, req(r"regex:ht-\d{4}-\d+"));
    assert_eq!((ids, recall), (BTreeSet::from([3]), Recall::Trigram));
    let (ids, recall, _) = run_all(&reader, req(r"regex:\d{2}"));
    assert_eq!((ids, recall), (BTreeSet::from([1, 3, 4]), Recall::Scan));
    let hl = reader.highlights(3, &parse(r"regex:HT-\d+").unwrap(), Mode::Loose).unwrap();
    assert_eq!(hl, vec![3..10]);
}

#[test]
fn text_matcher_agrees_with_indexed_search() {
    use xs_index::TextMatcher;
    let tmp = tempfile::tempdir().unwrap();
    let text = "第一行 合同金额\n第二行 Ｈｔ-2024 合同";
    let mut w = ContentWriter::open(tmp.path(), "inst-a").unwrap();
    w.put(&doc(1, text)).unwrap();
    w.commit(1).unwrap();
    let reader = ContentReader::open(tmp.path()).unwrap();
    for q in ["合同", "ht-2024 -草稿", r"regex:HT-\d+", r#""合同 金额"~2"#] {
        let expr = parse(q).unwrap();
        let m = TextMatcher::new(&expr, Mode::Loose);
        let mut s = reader.session(SearchRequest { expr: expr.clone(), mode: Mode::Loose, dirs: vec![], exts: vec![], scopes: vec![], size: None, mtime: None }).unwrap();
        let indexed = s.next(Duration::from_secs(5), 10, &AtomicBool::new(false)).unwrap().hits.pop().unwrap();
        let live = m.check(text).unwrap();
        assert_eq!((live.hit_count, &live.snippet, &live.snippet_highlights), (indexed.hit_count, &indexed.snippet, &indexed.snippet_highlights), "{q}");
        assert_eq!(m.highlights(text, usize::MAX).0, reader.highlights(1, &expr, Mode::Loose).unwrap(), "{q}");
    }
    assert!(TextMatcher::new(&parse("不存在").unwrap(), Mode::Loose).check(text).is_none());
}

#[test]
fn archive_members_are_separate_hits() {
    use xs_index::{Anchor, AnchorKind};
    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "inst-a").unwrap();
    // Two members: "合同" in both, "金额" only in the second; "附件" spans members.
    let text = "合同 附\n第二份 合同 金额 件\n";
    let mut d = doc(1, text);
    d.anchors = vec![
        Anchor { start: 0, kind: AnchorKind::Member { name: "a/一.txt".into() } },
        Anchor { start: 5, kind: AnchorKind::Member { name: "b/二.docx".into() } },
        Anchor { start: 9, kind: AnchorKind::Paragraph { index: 1 } },
    ];
    w.put(&d).unwrap();
    w.put(&doc(2, "普通文件 合同")).unwrap();
    w.commit(1).unwrap();
    let reader = ContentReader::open(tmp.path()).unwrap();
    let hits = |q: &str| {
        let mut s = reader.session(SearchRequest { expr: parse(q).unwrap(), mode: Mode::Loose, dirs: vec![], exts: vec![], scopes: vec![], size: None, mtime: None }).unwrap();
        let mut v: Vec<(u64, String, u32, String)> = s
            .next(Duration::from_secs(5), 100, &AtomicBool::new(false))
            .unwrap()
            .hits
            .into_iter()
            .map(|h| (h.file_id, h.member, h.member_start, h.snippet))
            .collect();
        v.sort();
        v
    };
    let both = hits("合同");
    assert_eq!(both.iter().map(|h| (h.0, h.1.as_str(), h.2)).collect::<Vec<_>>(), vec![(1, "a/一.txt", 0), (1, "b/二.docx", 5), (2, "", 0)]);
    assert_eq!(both[1].3, "第二份 合同 金额 件");
    assert_eq!(hits("合同 金额").iter().map(|h| h.1.as_str()).collect::<Vec<_>>(), vec!["b/二.docx"]);
    // Terms in different members do not make a hit.
    assert!(hits("附 件").is_empty());
}

/// Reference: the full source map, as highlights used to be computed.
fn reference_highlights(text: &str, query: &str, mode: Mode) -> Vec<std::ops::Range<u32>> {
    use xs_core::normalize::normalize;
    fn literals(e: &Expr, out: &mut Vec<String>) {
        match e {
            Expr::Literal(s) => out.push(s.clone()),
            Expr::And(x) | Expr::Or(x) => x.iter().for_each(|e| literals(e, out)),
            _ => {}
        }
    }
    let mut lits = vec![];
    literals(&parse(query).unwrap(), &mut lits);
    let n = normalize(text, mode);
    let starts: Vec<(usize, usize)> = n.text.char_indices().enumerate().map(|(i, (b, _))| (b, i)).collect();
    let scalar_at = |b: usize| starts.binary_search_by_key(&b, |x| x.0).map(|i| starts[i].1).unwrap_or(starts.len());
    let mut hits: Vec<std::ops::Range<usize>> = vec![];
    for l in lits {
        let l = normalize_text(&l, mode);
        let mut from = 0;
        while let Some(p) = n.text[from..].find(&l) {
            let b = from + p;
            hits.push(b..b + l.len());
            from = b + n.text[b..].chars().next().unwrap().len_utf8();
        }
    }
    hits.sort_by_key(|r| (r.start, r.end));
    let mut merged: Vec<std::ops::Range<usize>> = vec![];
    for r in hits {
        match merged.last_mut() {
            Some(m) if r.start < m.end => m.end = m.end.max(r.end),
            _ => merged.push(r),
        }
    }
    let mut src: Vec<std::ops::Range<usize>> = vec![];
    for r in merged {
        let (a, b) = (scalar_at(r.start), scalar_at(r.end));
        let r = n.source_spans[a].start..n.source_spans[b - 1].end;
        match src.last_mut() {
            Some(m) if r.start < m.end => m.end = m.end.max(r.end),
            _ => src.push(r),
        }
    }
    let mut utf16 = vec![0u32];
    for c in text.chars() {
        utf16.push(utf16.last().unwrap() + c.len_utf16() as u32);
    }
    src.into_iter().map(|r| utf16[r.start]..utf16[r.end]).collect()
}

#[test]
fn bounded_highlights_equal_the_full_source_map() {
    use xs_index::TextMatcher;
    let docs = corpus();
    let cases = ["数据", "a", "the", "合同", "数据 | 共享", "ﬁ", "café", "a  b"];
    let extra = ["ﬁnal ﬁ fi  x\t\n y Café CAFE\u{301} 😀数据😀", "aaaa aa   aaa", "ＡＢＣ abc ß SS ss"];
    let mut compared = 0;
    for text in docs.iter().map(|d| d.text.as_str()).chain(extra) {
        for q in cases {
            for mode in Mode::ALL {
                let m = TextMatcher::new(&parse(q).unwrap(), mode);
                let (got, total) = m.highlights(text, usize::MAX);
                let want = reference_highlights(text, q, mode);
                assert_eq!(got, want, "{q:?} {mode:?} {text:?}");
                assert!(total as usize >= got.len());
                // A cap returns the same prefix (mapping can merge, so compare what is common).
                let (few, total2) = m.highlights(text, 2);
                assert_eq!(total, total2);
                assert!(few.len() <= 2 && few.iter().zip(&want).all(|(a, b)| a.start == b.start));
                compared += 1;
            }
        }
    }
    assert!(compared > 100);
}

#[test]
fn preview_of_archive_member_is_one_consistent_slice() {
    use xs_index::{Anchor, AnchorKind};
    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "inst-a").unwrap();
    // Members start at scalars 0 and 5; "😀" is one scalar but two UTF-16 units.
    let mut d = doc(1, "😀甲乙\n\n丙丁 戊丁\n");
    d.anchors = vec![
        Anchor { start: 0, kind: AnchorKind::Member { name: "a.txt".into() } },
        Anchor { start: 5, kind: AnchorKind::Member { name: "b.docx".into() } },
        Anchor { start: 5, kind: AnchorKind::Paragraph { index: 1 } },
    ];
    w.put(&d).unwrap();
    w.commit(1).unwrap();
    let reader = ContentReader::open(tmp.path()).unwrap();
    let expr = parse("丁 | 甲").unwrap();
    let second = reader.preview(1, &expr, Mode::Loose, Some(5), 100).unwrap().unwrap();
    assert_eq!(second.doc.text, "丙丁 戊丁\n");
    assert_eq!(second.highlights, vec![1..2, 4..5]);
    assert_eq!(second.doc.anchors, vec![Anchor { start: 0, kind: AnchorKind::Paragraph { index: 1 } }]);
    let first = reader.preview(1, &expr, Mode::Loose, Some(0), 100).unwrap().unwrap();
    assert_eq!(first.doc.text, "😀甲乙\n\n");
    assert_eq!(first.highlights.first(), Some(&(2..3)));
    assert_eq!(first.highlights.len(), 1);
    let whole = reader.preview(1, &expr, Mode::Loose, None, 2).unwrap().unwrap();
    assert_eq!((whole.highlights.len(), whole.total_hits), (2, 3));
    assert!(reader.preview(9, &expr, Mode::Loose, None, 2).unwrap().is_none());
}

#[test]
fn large_archive_is_paged_member_by_member() {
    use xs_index::{Anchor, AnchorKind};
    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "inst-a").unwrap();
    let mut text = String::new();
    let mut anchors = vec![];
    for i in 0..10 {
        anchors.push(Anchor { start: text.chars().count() as u32, kind: AnchorKind::Member { name: format!("{i}.txt") } });
        text.push_str(&format!("合同 第{i}份\n"));
    }
    let mut d = doc(1, &text);
    d.anchors = anchors;
    w.put(&d).unwrap();
    w.commit(1).unwrap();
    let reader = ContentReader::open(tmp.path()).unwrap();
    let session = || reader.session(SearchRequest { expr: parse("合同").unwrap(), mode: Mode::Loose, dirs: vec![], exts: vec![], scopes: vec![], size: None, mtime: None }).unwrap();
    let never = AtomicBool::new(false);
    let mut s = session();
    let first = s.next(Duration::from_secs(5), 3, &never).unwrap();
    assert_eq!(first.hits.len(), 3, "max_hits holds inside one archive");
    assert!(!first.done, "the rest of the members are still to come");
    let mut members: Vec<String> = first.hits.into_iter().map(|h| h.member).collect();
    loop {
        let b = s.next(Duration::from_secs(5), 3, &never).unwrap();
        assert!(b.hits.len() <= 3);
        members.extend(b.hits.into_iter().map(|h| h.member));
        if b.done {
            break;
        }
    }
    assert_eq!(members, (0..10).map(|i| format!("{i}.txt")).collect::<Vec<_>>());
    // Cancelled between members: stops and does not report completion.
    let mut s = session();
    assert_eq!(s.next(Duration::from_secs(5), 1, &never).unwrap().hits.len(), 1);
    let b = s.next(Duration::from_secs(5), 100, &AtomicBool::new(true)).unwrap();
    assert!(b.hits.is_empty() && !b.done);
}

#[test]
fn size_and_time_filters_apply_to_candidates() {
    let tmp = tempfile::tempdir().unwrap();
    let mut w = ContentWriter::open(tmp.path(), "inst-a").unwrap();
    for (id, size, mtime) in [(1u64, 10i64, 100i64), (2, 500, 100), (3, 500, 900)] {
        let mut d = doc(id, "合同 文本");
        d.size = size;
        d.mtime = mtime;
        w.put(&d).unwrap();
    }
    w.commit(1).unwrap();
    let reader = ContentReader::open(tmp.path()).unwrap();
    let ids = |size: Option<(i64, i64)>, mtime: Option<(i64, i64)>| {
        let mut s = reader.session(SearchRequest { expr: parse("合同").unwrap(), mode: Mode::Loose, dirs: vec![], exts: vec![], scopes: vec![], size, mtime }).unwrap();
        // Filtered out before verification: the candidate count already says so.
        let n = s.candidates();
        let mut v: Vec<u64> = s.next(Duration::from_secs(5), 100, &AtomicBool::new(false)).unwrap().hits.iter().map(|h| h.file_id).collect();
        v.sort();
        assert_eq!(n, v.len());
        v
    };
    assert_eq!(ids(None, None), [1, 2, 3]);
    assert_eq!(ids(Some((100, 1000)), None), [2, 3]);
    assert_eq!(ids(None, Some((0, 500))), [1, 2]);
    assert_eq!(ids(Some((100, 1000)), Some((0, 500))), [2]);
    assert_eq!(reader.recall_of(&parse(r"regex:\d{2}").unwrap()), Recall::Scan);
}
