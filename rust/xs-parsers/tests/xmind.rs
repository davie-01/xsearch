use std::io::Write;
use xs_index::{AnchorKind, ExtractState};
use xs_parsers::{Limits, xmind::xmind};

fn zip(path: &std::path::Path, files: &[(&str, &str)]) {
    let mut z = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
    for (name, body) in files {
        z.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
        z.write_all(body.as_bytes()).unwrap();
    }
    z.finish().unwrap();
}

fn parts(e: &xs_parsers::Extraction) -> Vec<AnchorKind> {
    e.anchors.iter().map(|a| a.kind.clone()).collect()
}

fn part(name: &str) -> AnchorKind {
    AnchorKind::Part { name: name.into() }
}

#[test]
fn json_sheets_topics_notes_and_labels() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("plan.xmind");
    let content = r#"[
      {"id": "s1", "class": "sheet", "title": "项目计划",
       "rootTopic": {"id": "r", "title": "验收", "labels": ["重要", "Q4"],
         "notes": {"plain": {"content": "终验后\n30 日内支付\n"}, "realHTML": {"content": "<div>终验后</div>"}},
         "children": {
           "attached": [{"id": "a", "title": "支付\n条件", "children": {"attached": [{"id": "a1", "title": "首付 30%"}]}},
                        {"id": "b", "title": "文档", "notes": {"realHTML": {"content": "<p>需规</p><p>原型</p>"}}}],
           "detached": [{"id": "f", "title": "自由主题"}],
           "summary": [{"id": "s", "title": "概要"}]},
         "boundaries": [{"id": "x", "title": "范围"}]},
       "relationships": [{"id": "l", "end1Id": "a", "end2Id": "b", "title": "依赖"}]},
      {"id": "s2", "title": "", "rootTopic": {"id": "r2", "title": "第二张"}}
    ]"#;
    // XMind 2020+ also writes a content.xml stub telling old versions to upgrade.
    zip(&p, &[("content.json", content), ("content.xml", "<xmap-content><sheet><topic><title>Warning: upgrade</title></topic></sheet></xmap-content>"), ("manifest.json", r#"{"file-entries": {"content.json": {}}}"#)]);
    let e = xmind(&p, Limits::default()).unwrap();
    assert_eq!(
        e.text,
        "项目计划\n验收\n重要 Q4\n终验后\n30 日内支付\n支付 条件\n首付 30%\n文档\n需规\n原型\n自由主题\n概要\n范围\n依赖\n第二张\n"
    );
    assert_eq!(parts(&e), vec![part("项目计划"), part("画布 2")]);
    assert_eq!((e.state, e.method.as_str()), (ExtractState::Complete, "xmind"));
}

#[test]
fn legacy_xml_and_errors() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("old.xmind");
    let content = r#"<?xml version="1.0" encoding="UTF-8"?>
<xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" xmlns:xhtml="http://www.w3.org/1999/xhtml" version="2.0">
  <sheet id="s"><topic id="r"><title>需规标准</title>
    <labels><label>GB/T</label></labels>
    <notes><html><xhtml:p>第一段</xhtml:p><xhtml:p>第二段</xhtml:p></html></notes>
    <children><topics type="attached">
      <topic id="a"><title>前言</title><notes><plain>目的与范围</plain></notes></topic>
    </topics><topics type="detached"><topic id="d"><title>附录</title></topic></topics></children>
    <boundaries><boundary id="b"><title>章节</title></boundary></boundaries>
  </topic><title>画布 1</title>
  <relationships><relationship id="l"><title>参考</title></relationship></relationships></sheet>
</xmap-content>"#;
    zip(&p, &[("content.xml", content)]);
    let e = xmind(&p, Limits::default()).unwrap();
    assert_eq!(e.text, "画布 1\n需规标准\nGB/T\n第一段\n第二段\n前言\n目的与范围\n附录\n章节\n参考\n");
    assert_eq!(parts(&e), vec![part("画布 1")]);

    let enc = dir.path().join("locked.xmind");
    zip(&enc, &[("content.json", "QmluYXJ5"), ("manifest.json", r#"{"file-entries": {"content.json": {"encryption-data": {}}}}"#)]);
    assert!(xmind(&enc, Limits::default()).unwrap_err().to_string().contains("encrypted"));
    let empty = dir.path().join("empty.xmind");
    zip(&empty, &[("metadata.json", "{}")]);
    assert!(xmind(&empty, Limits::default()).is_err());
}
