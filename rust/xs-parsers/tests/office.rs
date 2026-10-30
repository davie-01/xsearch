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
