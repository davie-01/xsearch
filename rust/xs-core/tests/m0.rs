use tempfile::tempdir;
use xs_core::{
    extract,
    index::{Engine, GramKind, bloom, bloom_pass},
    normalize::{Mode, normalize, occurrences, scalar_to_utf8, scalar_to_utf16},
    query::{can_narrow, parse},
    recovery::{Coordinator, Fault},
};
fn ids(c: &Coordinator, instance: &str, q: &str) -> Vec<u64> {
    c.engines[instance]
        .search(&parse(q).unwrap(), Mode::Strict, false)
        .unwrap()
        .ids
}
#[test]
fn normalization_has_source_offsets_and_overlap() {
    let s = "😀ﬁ  \tcafe\u{301}𠀀";
    let n = normalize(s, Mode::Loose);
    assert_eq!(n.text, "😀fi cafe\u{301}𠀀");
    assert_eq!(n.source_range(1..3), Some(1..2));
    assert_eq!(n.source_range(3..4), Some(2..5));
    for hit in occurrences(&n.text, "fi") {
        let raw = n.source_range(hit).unwrap();
        let bytes = scalar_to_utf8(s, raw.clone()).unwrap();
        assert_eq!(&s[bytes], "ﬁ");
        assert_eq!(scalar_to_utf16(s, raw), Some(2..3));
    }
    assert_eq!(occurrences("aaa", "aa"), vec![0..2, 1..3]);
    assert_eq!(scalar_to_utf16("😀𠀀", 1..2), Some(2..4));
    assert_eq!(scalar_to_utf8("😀", 1..2), None);
    assert_eq!(
        normalize("a\u{315}\u{300}", Mode::Loose).text,
        "a\u{315}\u{300}"
    );
    assert_eq!(normalize("Straße", Mode::CaseSensitive).text, "Straße");
    assert_eq!(normalize("ﬁ", Mode::Strict).text, "ﬁ");
}
#[test]
fn parser_precedence_quoting_and_invalid_input() {
    let e = parse("a | b -c").unwrap();
    assert!(e.matches("a c", Mode::Strict));
    assert!(!e.matches("b c", Mode::Strict));
    assert!(e.matches("b", Mode::Strict));
    assert!(parse("\"a b\"").unwrap().matches("a b", Mode::Strict));
    assert!(parse("foo-bar").unwrap().matches("foo-bar", Mode::Strict));
    for q in ["", "|a", "a|", "-", "()", "(a", "a)", "\"", "\"\"", "a\\"] {
        assert!(parse(q).is_err(), "{q}");
    }
    // Nesting is bounded: deep pasted input is an error, not a stack overflow.
    let ok = format!("{}a{}", "(".repeat(64), ")".repeat(64));
    assert!(parse(&ok).is_ok());
    for q in [format!("{}a{}", "(".repeat(65), ")".repeat(65)), format!("{}a", "-".repeat(65)), "(".repeat(100_000)] {
        assert!(parse(&q).unwrap_err().to_string().contains("嵌套过深"), "{}", &q[..10]);
    }
    for (old, new) in [("-a", "-ab"), ("a", "a|b"), ("cafe", "cafe\u{301}")] {
        assert!(!can_narrow(&parse(old).unwrap(), &parse(new).unwrap()));
    }
}
#[test]
fn grams_tail_and_three_modes() {
    let d = tempdir().unwrap();
    let mut e = Engine::open(d.path(), GramKind::Byte, false).unwrap();
    for (i, t) in ["ab", "cab", "abc", "AB", "ﬁ", "fi", "cafe\u{301}"]
        .iter()
        .enumerate()
    {
        e.put(i as u64, 1, Some(t)).unwrap();
    }
    e.commit("test").unwrap();
    assert_eq!(
        e.search(&parse("ab").unwrap(), Mode::Loose, false)
            .unwrap()
            .ids,
        vec![0, 1, 2, 3]
    );
    assert_eq!(
        e.search(&parse("ab").unwrap(), Mode::Strict, false)
            .unwrap()
            .ids,
        vec![0, 1, 2]
    );
    assert_eq!(
        e.search(&parse("fi").unwrap(), Mode::CaseSensitive, false)
            .unwrap()
            .ids,
        vec![4, 5]
    );
    assert_eq!(
        e.search(&parse("fi").unwrap(), Mode::Strict, false)
            .unwrap()
            .ids,
        vec![5]
    );
    assert_eq!(
        e.search(&parse("cafe").unwrap(), Mode::Strict, false)
            .unwrap()
            .ids,
        vec![6]
    );
}
#[test]
fn bloom_no_false_negative_for_boolean_queries() {
    for t in ["abcdefghi 合同书 数据共享", "AI", "", "😀 café"] {
        let f = bloom(&normalize(t, Mode::Loose).text);
        for q in [
            "abc",
            "AI | 共享",
            "合同 -foo",
            "-abcdef",
            "不存在 | abc",
            "-(abc | foo)",
        ] {
            let e = parse(q).unwrap();
            if e.matches(t, Mode::Loose) {
                assert!(bloom_pass(&f, &e));
            }
            assert!(bloom_pass(&[], &e));
        }
    }
}
#[test]
fn text_encodings_and_malformed_bytes() {
    assert_eq!(
        extract::text(b"\xef\xbb\xbfhello", None).unwrap().text,
        "hello"
    );
    assert_eq!(
        extract::text(&[0xff, 0xfe, 0x2d, 0x4e], None).unwrap().text,
        "中"
    );
    assert!(extract::text(&[0xff, 0x00], None).is_err());
    assert_eq!(
        extract::text(&[0xd6, 0xd0], Some("gb18030")).unwrap().text,
        "中"
    );
}
#[test]
fn docx_structure_anchors() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Tests/Fixtures/m0/structure.docx");
    let e = extract::docx(&root).unwrap();
    for needle in [
        "正文合同",
        "表格单元格",
        "文本框数据共享",
        "页眉甲方",
        "页脚乙方",
        "脚注验收说明",
        "尾注编号2202",
    ] {
        assert_eq!(
            e.text.matches(needle).count(),
            1,
            "missing/duplicate {needle}"
        );
    }
    for a in &e.anchors {
        let b = scalar_to_utf8(&e.text, a.range.clone()).unwrap();
        assert!(!e.text[b].is_empty());
    }
}
#[test]
fn stale_completion_lease_replacement_and_delete_fence() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    let s1 = c.event(1, Some("old"), "create").unwrap();
    let stale = c.claim("initial", 1, s1).unwrap();
    assert!(c.claim("initial", 1, s1).is_err());
    c.db.execute("UPDATE jobs SET lease_until=0", []).unwrap();
    assert!(!c.stage(&stale).unwrap());
    let replacement = c.claim("initial", 1, s1).unwrap();
    assert!(!c.stage(&stale).unwrap());
    assert!(c.stage(&replacement).unwrap());
    let s2 = c.event(1, None, "delete").unwrap();
    c.commit("initial", Fault::None).unwrap();
    assert!(ids(&c, "initial", "old").is_empty());
    let delete = c.claim("initial", 1, s2).unwrap();
    assert!(c.stage(&delete).unwrap());
    c.commit("initial", Fault::None).unwrap();
    drop(c);
    let mut c = Coordinator::open(d.path()).unwrap();
    assert_eq!(c.engines["initial"].applied().unwrap()[&1], 2);
    assert!(!c.stage(&stale).unwrap());
    assert_eq!(
        c.event(1, Some("old"), "scope re-add same digest").unwrap(),
        3
    );
    c.drain("initial").unwrap();
    assert_eq!(ids(&c, "initial", "old"), vec![1]);
}
#[test]
fn rollback_reload_and_monotonic_per_instance_state() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    let s = c.event(1, Some("alpha"), "create").unwrap();
    let j = c.claim("initial", 1, s).unwrap();
    c.stage(&j).unwrap();
    assert!(c.commit("initial", Fault::BeforeCommit).is_err());
    assert!(ids(&c, "initial", "alpha").is_empty());
    c.drain("initial").unwrap();
    assert_eq!(ids(&c, "initial", "alpha"), vec![1]);
    c.begin_rebuild("v2").unwrap();
    let j = c.claim("v2", 1, s).unwrap();
    assert!(c.stage(&j).unwrap());
    c.commit("v2", Fault::None).unwrap();
    assert_eq!(ids(&c, "v2", "alpha"), vec![1]);
}
#[test]
fn only_one_unacknowledged_commit_and_recovery() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    let s = c.event(1, Some("alpha"), "create").unwrap();
    let j = c.claim("initial", 1, s).unwrap();
    c.stage(&j).unwrap();
    assert!(c.commit("initial", Fault::AfterCommitBeforeAck).is_err());
    assert!(c.commit("initial", Fault::None).is_err());
    drop(c);
    let c = Coordinator::open(d.path()).unwrap();
    assert_eq!(c.status(&j).unwrap(), "acked");
    assert_eq!(ids(&c, "initial", "alpha"), vec![1]);
}
#[test]
fn ambiguous_committed_resolves_from_payload() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    let s = c.event(1, Some("alpha"), "create").unwrap();
    let j = c.claim("initial", 1, s).unwrap();
    c.stage(&j).unwrap();
    c.commit("initial", Fault::AmbiguousCommitted).unwrap();
    assert_eq!(c.status(&j).unwrap(), "acked");
}
#[test]
fn rebuild_dual_writes_cutover_and_late_tasks() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    c.event(1, Some("alpha"), "create").unwrap();
    c.drain("initial").unwrap();
    c.begin_rebuild("v2").unwrap();
    let s = c.event(1, Some("beta"), "extractor upgrade").unwrap();
    let late = c.claim("initial", 1, s).unwrap();
    c.drain("v2").unwrap();
    assert_eq!(ids(&c, "v2", "beta"), vec![1]);
    c.cutover("v2", Fault::None).unwrap();
    assert_eq!(c.active().unwrap(), "v2");
    assert!(!c.stage(&late).unwrap());
    assert!(c.cutover("unknown", Fault::None).is_err());
    c.event(1, None, "scope removal").unwrap();
    c.drain("v2").unwrap();
    assert!(ids(&c, "v2", "beta").is_empty());
    drop(c);
    let c = Coordinator::open(d.path()).unwrap();
    assert_eq!(c.active().unwrap(), "v2");
    assert_eq!(c.engines.len(), 1);
    assert_eq!(c.engines["v2"].applied().unwrap()[&1], 3);
}
#[test]
fn durable_cursors_are_independent_and_jobs_unique() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    c.event(1, Some("alpha"), "create").unwrap();
    assert_eq!(c.cursor("source").unwrap(), 1);
    assert_eq!(c.cursor("content:initial").unwrap(), 1);
    assert_eq!(c.cursor("name").unwrap(), 0);
    drop(c);
    let mut c = Coordinator::open(d.path()).unwrap();
    c.publish_names().unwrap();
    assert_eq!(c.cursor("name").unwrap(), 1);
    c.begin_rebuild("v2").unwrap();
    c.event(1, Some("alpha"), "config changed same bytes")
        .unwrap();
    assert_eq!(c.cursor("content:v2").unwrap(), 2);
    assert_eq!(c.cursor("name").unwrap(), 1);
    let count: u64 =
        c.db.query_row(
            "SELECT COUNT(*) FROM jobs WHERE instance='initial'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 2);
    assert!(
        c.db.execute(
            "INSERT INTO jobs(instance,file,seq) VALUES('initial',1,2)",
            []
        )
        .is_err()
    );
    c.drain("initial").unwrap();
    assert_eq!(c.engines["initial"].applied().unwrap()[&1], 2);
}
#[test]
fn ambiguous_not_committed_releases_sequence_fence() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    let s = c.event(1, Some("alpha"), "create").unwrap();
    let j = c.claim("initial", 1, s).unwrap();
    c.stage(&j).unwrap();
    assert!(c.commit("initial", Fault::AmbiguousNotCommitted).is_err());
    c.drain("initial").unwrap();
    assert_eq!(ids(&c, "initial", "alpha"), vec![1]);
}
#[test]
fn name_cache_requires_same_context_and_complete_results() {
    use xs_core::query::{NameContext, can_reuse};
    let old = parse("a").unwrap();
    let new = parse("ab").unwrap();
    let context = NameContext {
        generation: 1,
        options: "literal-insensitive".into(),
        scope: "/A".into(),
    };
    assert!(can_reuse(&old, &new, &context, &context, true));
    assert!(!can_reuse(&old, &new, &context, &context, false));
    for changed in [
        NameContext {
            generation: 2,
            ..context.clone()
        },
        NameContext {
            options: "regex".into(),
            ..context.clone()
        },
        NameContext {
            scope: "/B".into(),
            ..context.clone()
        },
    ] {
        assert!(!can_reuse(&old, &new, &context, &changed, true));
    }
}
#[test]
fn c_abi_rejects_invalid_utf8_and_roundtrips_embedded_nul() {
    use std::ffi::CStr;
    use xs_core::ffi::{xs_normalize_utf8, xs_string_free};
    unsafe {
        assert!(xs_normalize_utf8(std::ptr::null(), 0, 0).is_null());
        assert!(xs_normalize_utf8([0xff].as_ptr(), 1, 0).is_null());
        assert!(xs_normalize_utf8(b"x".as_ptr(), 1, 9).is_null());
        let p = xs_normalize_utf8(b"A\0B".as_ptr(), 3, 0);
        let json: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(p).to_str().unwrap()).unwrap();
        assert_eq!(json["text"], "a\0b");
        xs_string_free(p);
    }
    assert_eq!(unicode_normalization::UNICODE_VERSION, (17, 0, 0));
}
#[test]
fn rebuild_and_lagging_name_consumer_protect_journal() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    c.event(1, Some("one"), "create").unwrap();
    c.publish_names().unwrap();
    c.begin_rebuild("v2").unwrap();
    c.event(1, Some("two"), "modify").unwrap();
    c.event(1, Some("three"), "modify").unwrap();
    assert_eq!(c.prune_journal().unwrap(), 0);
    c.publish_names().unwrap();
    assert_eq!(c.prune_journal().unwrap(), 0);
    c.cutover("v2", Fault::None).unwrap();
    assert_eq!(c.prune_journal().unwrap(), 2);
    assert_eq!(ids(&c, "v2", "three"), vec![1]);
}
#[test]
fn expired_staged_lease_requeues_latest_job_instead_of_losing_it() {
    let d = tempdir().unwrap();
    let mut c = Coordinator::open(d.path()).unwrap();
    let s = c.event(1, Some("latest"), "create").unwrap();
    let j = c.claim("initial", 1, s).unwrap();
    c.stage(&j).unwrap();
    c.db.execute("UPDATE jobs SET lease_until=0", []).unwrap();
    c.commit("initial", Fault::None).unwrap();
    assert_eq!(c.status(&j).unwrap(), "pending");
    assert!(ids(&c, "initial", "latest").is_empty());
    c.drain("initial").unwrap();
    assert_eq!(ids(&c, "initial", "latest"), vec![1]);
}
#[test]
fn incompatible_normalization_is_rejected_before_search() {
    let d = tempdir().unwrap();
    let mut e = Engine::open(d.path(), GramKind::Byte, false).unwrap();
    let mut doc = tantivy::TantivyDocument::default();
    doc.add_u64(e.fields.id, 1);
    doc.add_u64(e.fields.seq, 1);
    doc.add_u64(e.fields.live, 1);
    doc.add_text(e.fields.norm, "obsolete");
    doc.add_text(e.fields.text, "alpha");
    e.writer.add_document(doc).unwrap();
    e.commit("old version").unwrap();
    drop(e);
    assert!(Engine::open(d.path(), GramKind::Byte, false).is_err());
}
