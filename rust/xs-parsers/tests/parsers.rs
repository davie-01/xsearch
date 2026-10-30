use std::io::Write;
use xs_index::{AnchorKind, ExtractState};
use xs_parsers::{Limits, decode_text, docx, plain_text};

fn write_tmp(dir: &tempfile::TempDir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let p = dir.path().join(name);
    std::fs::write(&p, bytes).unwrap();
    p
}

#[test]
fn text_encodings() {
    let utf8 = "合同 数据共享 café\n第二行";
    assert_eq!(
        decode_text(utf8.as_bytes(), false).unwrap().method,
        "text/utf-8"
    );
    let mut bom = vec![0xEF, 0xBB, 0xBF];
    bom.extend_from_slice(utf8.as_bytes());
    let e = decode_text(&bom, false).unwrap();
    assert_eq!(e.text, utf8);
    let mut utf16 = vec![0xFF, 0xFE];
    for u in utf8.encode_utf16() {
        utf16.extend_from_slice(&u.to_le_bytes());
    }
    let e = decode_text(&utf16, false).unwrap();
    assert_eq!(
        (e.text.as_str(), e.method.as_str(), e.state),
        (utf8, "text/UTF-16LE", ExtractState::Complete)
    );
    let (gb, _, _) = encoding_rs::GB18030.encode("项目实施方案（专项债）");
    let e = decode_text(&gb, false).unwrap();
    assert_eq!(
        (e.text.as_str(), e.method.as_str()),
        ("项目实施方案（专项债）", "text/gb18030")
    );
    assert!(
        decode_text(b"\x89PNG\r\n\x1a\n\0\0\0IHDR", false).is_err(),
        "binary rejected"
    );
    let e = decode_text(b"ok \xff\xfe\xfd tail", false).unwrap();
    assert_eq!(e.state, ExtractState::Partial);
    assert!(!e.warnings.is_empty());
}

#[test]
fn size_limit_truncates_on_a_char_boundary() {
    let dir = tempfile::tempdir().unwrap();
    let text = "数据".repeat(1000); // 6000 bytes
    let p = write_tmp(&dir, "big.txt", text.as_bytes());
    // 4001 bytes cuts inside a 3-byte character.
    let e = plain_text(
        &p,
        Limits {
            max_file_bytes: 4001,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(e.state, ExtractState::Partial);
    assert_eq!(e.method, "text/utf-8");
    assert!(text.starts_with(&e.text) && e.text.len() == 3999);
}

fn make_docx(dir: &tempfile::TempDir) -> std::path::PathBuf {
    let w = |inner: &str| {
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{inner}</w:body></w:document>"#
        )
    };
    let p = |t: &str| format!("<w:p><w:r><w:t>{t}</w:t></w:r></w:p>");
    let cell = |t: &str, span: Option<u32>| {
        let pr = span
            .map(|s| format!(r#"<w:tcPr><w:gridSpan w:val="{s}"/></w:tcPr>"#))
            .unwrap_or_default();
        format!("<w:tc>{pr}{}</w:tc>", p(t))
    };
    let body = [
        p("第一段 合同"),
        // Run with a tab, a break, tracked deletion and a text box with its own paragraph.
        r#"<w:p><w:r><w:t>甲</w:t><w:tab/><w:t>乙</w:t><w:br/><w:t>丙</w:t></w:r><w:del><w:r><w:delText>已删除</w:delText></w:r></w:del><w:r><w:pict><w:txbxContent><w:p><w:r><w:t>文本框内容</w:t></w:r></w:p></w:txbxContent></w:pict></w:r></w:p>"#.into(),
        format!("<w:tbl><w:tr>{}{}</w:tr><w:tr>{}{}{}</w:tr></w:tbl>", cell("合并单元格", Some(2)), cell("C1 内容", None), cell("A2", None), cell("B2 金额", None), cell("C2", None)),
        format!("<w:tbl><w:tr>{}</w:tr></w:tbl>", cell("第二个表", None)),
        p("结尾"),
    ]
    .concat();
    let path = dir.path().join("t.docx");
    let mut z = zip::ZipWriter::new(std::fs::File::create(&path).unwrap());
    let opts = zip::write::SimpleFileOptions::default();
    for (name, xml) in [
        ("word/document.xml", w(&body)),
        ("word/header1.xml", w(&p("机密 页眉"))),
        ("word/footer1.xml", w(&p("第 1 页 页脚"))),
        ("word/styles.xml", w(&p("样式里的文字不应出现"))),
    ] {
        z.start_file(name, opts).unwrap();
        z.write_all(xml.as_bytes()).unwrap();
    }
    z.finish().unwrap();
    path
}

#[test]
fn docx_text_and_anchors() {
    let dir = tempfile::tempdir().unwrap();
    let e = docx::extract(&make_docx(&dir), Limits::default()).unwrap();
    assert_eq!(e.state, ExtractState::Complete);
    let lines: Vec<&str> = e.text.lines().collect();
    assert_eq!(
        lines,
        vec![
            "第一段 合同",
            "甲\t乙",
            "丙",
            "文本框内容",
            "合并单元格",
            "C1 内容",
            "A2",
            "B2 金额",
            "C2",
            "第二个表",
            "结尾",
            "机密 页眉",
            "第 1 页 页脚",
        ]
    );
    assert!(!e.text.contains("已删除") && !e.text.contains("样式里"));
    let label = |needle: &str| {
        let at = e.text[..e.text.find(needle).unwrap()].chars().count() as u32;
        e.anchors
            .iter()
            .rfind(|a| a.start <= at)
            .unwrap()
            .kind
            .clone()
    };
    assert_eq!(label("第一段"), AnchorKind::Paragraph { index: 1 });
    assert_eq!(
        label("合并单元格"),
        AnchorKind::Cell {
            table: 1,
            cell: "A1".into()
        }
    );
    assert_eq!(
        label("C1 内容"),
        AnchorKind::Cell {
            table: 1,
            cell: "C1".into()
        },
        "gridSpan shifts columns"
    );
    assert_eq!(
        label("B2 金额"),
        AnchorKind::Cell {
            table: 1,
            cell: "B2".into()
        }
    );
    assert_eq!(
        label("第二个表"),
        AnchorKind::Cell {
            table: 2,
            cell: "A1".into()
        }
    );
    assert!(e.anchors.iter().any(|a| a.kind
        == AnchorKind::Part {
            name: "页眉".into()
        }));
    assert!(e.anchors.iter().any(|a| a.kind
        == AnchorKind::Part {
            name: "页脚".into()
        }));
    assert!(e.anchors.windows(2).all(|w| w[0].start <= w[1].start));
}

#[test]
fn docx_fixture_covers_every_text_run() {
    let fixture = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../Tests/Fixtures/m0/structure.docx"
    );
    let e = docx::extract(std::path::Path::new(fixture), Limits::default()).unwrap();
    // Independent check: every <w:t> of the body parts appears in the output.
    let mut z = zip::ZipArchive::new(std::fs::File::open(fixture).unwrap()).unwrap();
    let mut xml = String::new();
    std::io::Read::read_to_string(&mut z.by_name("word/document.xml").unwrap(), &mut xml).unwrap();
    let doc = roxmltree::Document::parse(&xml).unwrap();
    let runs: Vec<&str> = doc
        .descendants()
        .filter(|n| n.tag_name().name() == "t")
        .filter_map(|n| n.text())
        .collect();
    assert!(!runs.is_empty());
    for r in runs {
        assert!(e.text.contains(r), "missing run {r:?}");
    }
}

#[test]
fn docx_unpacked_limit_marks_partial() {
    let dir = tempfile::tempdir().unwrap();
    let e = docx::extract(
        &make_docx(&dir),
        Limits {
            max_unpacked_bytes: 600,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(e.state, ExtractState::Partial);
}
