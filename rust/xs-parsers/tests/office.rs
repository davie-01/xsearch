use std::io::Write;
use xs_index::{AnchorKind, ExtractState};
use xs_parsers::{Limits, office};

fn zip(path: &std::path::Path, files: &[(&str, String)]) {
    let mut z = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
    for (name, body) in files {
        z.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
        z.write_all(body.as_bytes()).unwrap();
    }
    z.finish().unwrap();
}

#[test]
fn xlsx_rows_and_cell_anchors() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("t.xlsx");
    let ns = r#"xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#;
    zip(&p, &[
        ("[Content_Types].xml", r#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>"#.into()),
        ("_rels/.rels", r#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#.into()),
        ("xl/workbook.xml", format!(r#"<?xml version="1.0"?><workbook {ns}><sheets><sheet name="预算" sheetId="1" r:id="rId1"/></sheets></workbook>"#)),
        ("xl/_rels/workbook.xml.rels", r#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>"#.into()),
        ("xl/sharedStrings.xml", format!(r#"<?xml version="1.0"?><sst {ns} count="3" uniqueCount="3"><si><t>项目</t></si><si><t>金额</t></si><si><t>数据共享平台</t></si></sst>"#)),
        ("xl/worksheets/sheet1.xml", format!(r#"<?xml version="1.0"?><worksheet {ns}><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="3"><c r="B3" t="s"><v>2</v></c><c r="D3"><v>1200000</v></c></row></sheetData></worksheet>"#)),
    ]);
    let e = office::spreadsheet(&p, Limits::default()).unwrap();
    assert_eq!(e.text.lines().collect::<Vec<_>>(), vec!["项目\t金额", "数据共享平台\t1200000"]);
    assert_eq!(e.anchors[1].kind, AnchorKind::Sheet { sheet: "预算".into(), cell: "B3".into() });
    assert_eq!(e.state, ExtractState::Complete);
}

#[test]
fn pptx_slides_in_numeric_order_with_notes() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("t.pptx");
    let slide = |t: &str| format!(r#"<p:sld xmlns:p="p" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:p><a:r><a:t>{t}</a:t></a:r><a:br/><a:r><a:t>第二行</a:t></a:r></a:p></p:sld>"#);
    zip(&p, &[
        ("ppt/slides/slide10.xml", slide("第十页 结论")),
        ("ppt/slides/slide2.xml", slide("第二页 合同")),
        ("ppt/notesSlides/notesSlide2.xml", r#"<p:notes xmlns:p="p" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:p><a:r><a:t>2</a:t></a:r></a:p><a:p><a:r><a:t>讲者备注 预算说明</a:t></a:r></a:p></p:notes>"#.into()),
    ]);
    let e = office::pptx(&p, Limits::default()).unwrap();
    let pos = |s: &str| e.text.find(s).unwrap();
    assert!(pos("第二页") < pos("讲者备注") && pos("讲者备注") < pos("第十页"));
    assert!(e.text.contains("合同\n第二行"));
    let kinds: Vec<_> = e.anchors.iter().map(|a| a.kind.clone()).collect();
    assert_eq!(kinds, vec![AnchorKind::Slide { slide: 2 }, AnchorKind::Part { name: "备注 2".into() }, AnchorKind::Slide { slide: 10 }]);
}

#[test]
fn ofd_pages_follow_document_order() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("t.ofd");
    let content = |lines: &[&str]| {
        let objs: String = lines.iter().map(|l| format!(r#"<ofd:TextObject ID="1"><ofd:TextCode X="0" Y="0">{l}</ofd:TextCode></ofd:TextObject>"#)).collect();
        format!(r#"<ofd:Page xmlns:ofd="http://www.ofdspec.org/2016"><ofd:Content><ofd:Layer>{objs}</ofd:Layer></ofd:Content></ofd:Page>"#)
    };
    zip(&p, &[
        ("OFD.xml", r#"<ofd:OFD xmlns:ofd="http://www.ofdspec.org/2016"><ofd:DocBody><ofd:DocRoot>Doc_0/Document.xml</ofd:DocRoot></ofd:DocBody></ofd:OFD>"#.into()),
        ("Doc_0/Document.xml", r#"<ofd:Document xmlns:ofd="http://www.ofdspec.org/2016"><ofd:Pages><ofd:Page ID="2" BaseLoc="Pages/Page_1/Content.xml"/><ofd:Page ID="3" BaseLoc="Pages/Page_0/Content.xml"/></ofd:Pages></ofd:Document>"#.into()),
        ("Doc_0/Pages/Page_1/Content.xml", content(&["电子公文 第一页", "发文字号"])),
        ("Doc_0/Pages/Page_0/Content.xml", content(&["第二页 附件"])),
    ]);
    let e = office::ofd(&p, Limits::default()).unwrap();
    assert_eq!(e.text.lines().collect::<Vec<_>>(), vec!["电子公文 第一页", "发文字号", "第二页 附件"]);
    assert_eq!(e.anchors.iter().map(|a| a.kind.clone()).collect::<Vec<_>>(), vec![AnchorKind::Page { page: 1 }, AnchorKind::Page { page: 2 }]);
}

#[test]
fn scanned_ofd_pages_wait_for_ocr() {
    let dir = tempfile::tempdir().unwrap();
    let image = r#"<ofd:Page xmlns:ofd="http://www.ofdspec.org/2016"><ofd:Content><ofd:Layer><ofd:ImageObject ID="5" ResourceID="9"/></ofd:Layer></ofd:Content></ofd:Page>"#;
    let text = r#"<ofd:Page xmlns:ofd="http://www.ofdspec.org/2016"><ofd:Content><ofd:Layer><ofd:TextObject ID="1"><ofd:TextCode>正文</ofd:TextCode></ofd:TextObject></ofd:Layer></ofd:Content></ofd:Page>"#;
    let build = |name: &str, pages: &[&str]| {
        let p = dir.path().join(name);
        let mut files = vec![
            ("OFD.xml", r#"<ofd:OFD xmlns:ofd="http://www.ofdspec.org/2016"><ofd:DocBody><ofd:DocRoot>Doc_0/Document.xml</ofd:DocRoot></ofd:DocBody></ofd:OFD>"#.to_string()),
        ];
        let locs: String = (0..pages.len()).map(|i| format!(r#"<ofd:Page ID="{i}" BaseLoc="Pages/Page_{i}/Content.xml"/>"#)).collect();
        files.push(("Doc_0/Document.xml", format!(r#"<ofd:Document xmlns:ofd="http://www.ofdspec.org/2016"><ofd:Pages>{locs}</ofd:Pages></ofd:Document>"#)));
        let names: Vec<String> = (0..pages.len()).map(|i| format!("Doc_0/Pages/Page_{i}/Content.xml")).collect();
        for (i, body) in pages.iter().enumerate() {
            files.push((names[i].as_str(), body.to_string()));
        }
        zip(&p, &files);
        office::ofd(&p, Limits::default()).unwrap()
    };
    assert_eq!(build("scan.ofd", &[image, image]).state, ExtractState::WaitingOcr);
    let mixed = build("mixed.ofd", &[text, image]);
    assert_eq!((mixed.state, mixed.warnings.len()), (ExtractState::Partial, 1));
}

/// A minimal binary PowerPoint stream, records as [MS-PPT] lays them out.
fn rec(ver: u16, inst: u16, rtype: u16, body: &[u8]) -> Vec<u8> {
    let mut v = (ver | (inst << 4)).to_le_bytes().to_vec();
    v.extend(rtype.to_le_bytes());
    v.extend((body.len() as u32).to_le_bytes());
    v.extend(body);
    v
}
fn chars(t: &str) -> Vec<u8> {
    rec(0, 0, 0x0FA0, &t.encode_utf16().flat_map(u16::to_le_bytes).collect::<Vec<_>>())
}
fn persist_atom(persist: u32, slide_id: u32) -> Vec<u8> {
    let mut b = vec![];
    for v in [persist, 0, 0, slide_id, 0] {
        b.extend(v.to_le_bytes());
    }
    rec(0, 0, 0x03F3, &b)
}
fn slide_atom(notes_id: u32) -> Vec<u8> {
    let mut b = vec![0u8; 16];
    b.extend(notes_id.to_le_bytes());
    b.extend([0u8; 4]);
    rec(2, 0, 0x03EF, &b)
}

#[test]
fn binary_ppt_follows_persist_directory() {
    // Version 1 of the deck (superseded), then version 2 appended by an incremental save.
    let doc = |title: &str| {
        let mut slides = persist_atom(1, 256);
        slides.extend(chars(title));
        let mut notes = persist_atom(2, 300);
        notes.extend(chars("讲者备注"));
        let mut body = rec(0xF, 0, 0x0FF0, &slides);
        body.extend(rec(0xF, 2, 0x0FF0, &notes));
        rec(0xF, 0, 0x03E8, &body)
    };
    let slide = |boxed: &str| {
        let mut body = slide_atom(300);
        body.extend(rec(0xF, 0, 0x040C, &chars(boxed)));
        rec(0xF, 0, 0x03EE, &body)
    };
    let mut s = vec![];
    s.extend(rec(0xF, 0, 0x03F8, &chars("单击此处编辑母版标题样式")));
    // An unreferenced title master is also a slide container.
    s.extend(rec(0xF, 0, 0x03EE, &chars("单击此处编辑母版副标题样式")));
    let old_slide = s.len();
    s.extend(slide("旧文本框"));
    s.extend(doc("旧标题"));
    let notes_at = s.len();
    s.extend(rec(0xF, 0, 0x03F0, &rec(0xF, 0, 0x040C, &chars("备注页文本框"))));
    let dir = |slide_at: usize| {
        let mut b = (1u32 | (2 << 20)).to_le_bytes().to_vec();
        b.extend((slide_at as u32).to_le_bytes());
        b.extend((notes_at as u32).to_le_bytes());
        rec(0, 0, 0x1772, &b)
    };
    s.extend(dir(old_slide));
    let new_slide = s.len();
    s.extend(slide("新文本框"));
    s.extend(doc("新标题"));
    s.extend(dir(new_slide));

    let dir_path = tempfile::tempdir().unwrap();
    let p = dir_path.path().join("deck.ppt");
    let mut ole = cfb::create(&p).unwrap();
    ole.create_stream("/PowerPoint Document").unwrap().write_all(&s).unwrap();
    ole.flush().unwrap();
    drop(ole);
    let e = office::pptx(&p, Limits::default()).unwrap();
    assert_eq!(e.method, "ppt");
    assert_eq!(e.text.lines().collect::<Vec<_>>(), vec!["新标题", "新文本框", "讲者备注", "备注页文本框"]);
    let kinds: Vec<_> = e.anchors.iter().map(|a| a.kind.clone()).collect();
    assert_eq!(kinds, vec![AnchorKind::Slide { slide: 1 }, AnchorKind::Part { name: "备注 1".into() }]);
}

#[test]
fn pptx_follows_presentation_order_and_slide_relationships() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("t.pptx");
    let a = r#"xmlns:p="p" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#;
    let slide = |t: &str| format!(r#"<p:sld {a}><a:p><a:r><a:t>{t}</a:t></a:r></a:p></p:sld>"#);
    let notes = |t: &str| format!(r#"<p:notes {a}><a:p><a:r><a:t>{t}</a:t></a:r></a:p></p:notes>"#);
    let t = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    let rel = |target: &str, kind: &str| format!(r#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{t}/{kind}" Target="{target}"/></Relationships>"#);
    // Shown as slide3, slide1 (slide2 was deleted but its part stays); notes numbered the other way.
    zip(&p, &[
        ("ppt/presentation.xml", format!(r#"<p:presentation xmlns:p="p" xmlns:r="{t}"><p:sldIdLst><p:sldId id="258" r:id="rId8"/><p:sldId id="256" r:id="rId7"/></p:sldIdLst></p:presentation>"#)),
        ("ppt/_rels/presentation.xml.rels", format!(r#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId7" Type="{t}/slide" Target="slides/slide1.xml"/><Relationship Id="rId8" Type="{t}/slide" Target="/ppt/slides/slide3.xml"/><Relationship Id="rId9" Type="{t}/theme" Target="theme/theme1.xml"/></Relationships>"#)),
        ("ppt/slides/slide1.xml", slide("原第一页")),
        ("ppt/slides/slide2.xml", slide("已删除的页")),
        ("ppt/slides/slide3.xml", slide("原第三页")),
        ("ppt/slides/_rels/slide1.xml.rels", rel("../notesSlides/notesSlide3.xml", "notesSlide")),
        ("ppt/slides/_rels/slide3.xml.rels", rel("../notesSlides/notesSlide1.xml", "notesSlide")),
        ("ppt/notesSlides/notesSlide1.xml", notes("第三页的备注")),
        ("ppt/notesSlides/notesSlide3.xml", notes("第一页的备注")),
    ]);
    let e = office::pptx(&p, Limits::default()).unwrap();
    assert_eq!(e.text, "原第三页\n第三页的备注\n原第一页\n第一页的备注\n");
    let kinds: Vec<_> = e.anchors.iter().map(|a| a.kind.clone()).collect();
    assert_eq!(kinds, vec![
        AnchorKind::Slide { slide: 1 },
        AnchorKind::Part { name: "备注 1".into() },
        AnchorKind::Slide { slide: 2 },
        AnchorKind::Part { name: "备注 2".into() },
    ]);
}

#[test]
fn unreadable_sheet_makes_the_workbook_partial() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("t.xlsx");
    let ns = r#"xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#;
    let t = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    zip(&p, &[
        ("[Content_Types].xml", r#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>"#.into()),
        ("_rels/.rels", format!(r#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{t}/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)),
        ("xl/workbook.xml", format!(r#"<?xml version="1.0"?><workbook {ns}><sheets><sheet name="好" sheetId="1" r:id="rId1"/><sheet name="坏" sheetId="2" r:id="rId2"/></sheets></workbook>"#)),
        ("xl/_rels/workbook.xml.rels", format!(r#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{t}/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="{t}/worksheet" Target="worksheets/sheet2.xml"/></Relationships>"#)),
        ("xl/worksheets/sheet1.xml", format!(r#"<?xml version="1.0"?><worksheet {ns}><sheetData><row r="1"><c r="A1"><v>7</v></c></row></sheetData></worksheet>"#)),
        ("xl/worksheets/sheet2.xml", "<worksheet><sheetData><row".into()),
    ]);
    let e = office::spreadsheet(&p, Limits::default()).unwrap();
    assert_eq!(e.text.trim(), "7");
    assert_eq!(e.state, ExtractState::Partial);
    assert!(e.warnings.iter().any(|w| w.contains("坏")), "{:?}", e.warnings);
}

#[test]
fn workbook_declaring_too_much_is_refused_before_reading() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("t.xlsx");
    let big = "x".repeat(10_000);
    zip(&p, &[("xl/workbook.xml", big)]);
    let small = Limits { max_file_bytes: 1 << 20, max_unpacked_bytes: 1000 };
    assert!(office::spreadsheet(&p, small).unwrap_err().to_string().contains("uncompressed size limit"));
}
