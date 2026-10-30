use std::io::Write;
use xs_index::{AnchorKind, ExtractState};
use xs_parsers::{Limits, web};

#[test]
fn html_text_without_markup() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.html");
    std::fs::write(&p, r#"<!DOCTYPE html><html><head><title>合同 &amp; 协议</title>
<style>p { color: red }</style><script>var x = "<p>不要</p>";</script></head>
<body><!-- 注释 --><h1>第一章</h1><p>甲方&nbsp;向乙方支付 &#x4E07;元 &lt;含税&gt;</p>
<table><tr><td>项目</td><td>金额</td></tr><tr><td>A</td><td>1 &lt; 2</td></tr></table>
<pre>行一
行二</pre><p>未闭合 <b>粗体 a < b <div>块</body></html>"#).unwrap();
    let e = web::html(&p, Limits::default()).unwrap();
    let lines: Vec<&str> = e.text.lines().collect();
    assert_eq!(lines, vec!["合同 & 协议", "第一章", "甲方 向乙方支付 万元 <含税>", "项目\t金额", "A\t1 < 2", "行一", "行二", "未闭合 粗体 a < b", "块"]);
    assert!(!e.text.contains("color") && !e.text.contains("不要") && !e.text.contains("注释"));
    assert_eq!(e.anchors[2].kind, AnchorKind::Paragraph { index: 3 });
    assert_eq!(e.state, ExtractState::Complete);
}

#[test]
fn html_declared_charset() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("gbk.htm");
    let (body, _, _) = encoding_rs::GBK.encode("<html><head><meta charset=\"gbk\"></head><body><p>数据共享平台</p></body></html>");
    std::fs::write(&p, &body).unwrap();
    let e = web::html(&p, Limits::default()).unwrap();
    assert_eq!((e.text.trim(), e.method.as_str()), ("数据共享平台", "html/gbk"));
}

#[test]
fn epub_spine_order_and_chapter_anchors() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("b.epub");
    let mut z = zip::ZipWriter::new(std::fs::File::create(&p).unwrap());
    let files = [
        ("mimetype", "application/epub+zip".to_string()),
        ("META-INF/container.xml", r#"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#.into()),
        ("OEBPS/content.opf", r#"<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="c2" href="text/ch%202.xhtml"/><item id="c1" href="text/ch1.xhtml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>"#.into()),
        ("OEBPS/text/ch1.xhtml", "<html><body><h1>序言</h1><p>第一段</p></body></html>".into()),
        ("OEBPS/text/ch 2.xhtml", "<html><body><p>没有标题的章节</p></body></html>".into()),
    ];
    for (name, body) in files {
        z.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
        z.write_all(body.as_bytes()).unwrap();
    }
    z.finish().unwrap();
    let e = web::epub(&p, Limits::default()).unwrap();
    assert_eq!(e.text.lines().collect::<Vec<_>>(), vec!["序言", "第一段", "没有标题的章节"]);
    let parts: Vec<_> = e.anchors.iter().filter_map(|a| match &a.kind { AnchorKind::Part { name } => Some(name.as_str()), _ => None }).collect();
    assert_eq!(parts, vec!["序言", "第 2 章"]);
}

#[test]
fn ampersand_before_multibyte_text() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("c.html");
    std::fs::write(&p, "<p>A&数据共享网站 &amp;</p>").unwrap();
    assert_eq!(web::html(&p, Limits::default()).unwrap().text.trim(), "A&数据共享网站 &");
}

#[test]
fn epub_folder_and_lenient_opf() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("book.epub");
    std::fs::create_dir_all(root.join("META-INF")).unwrap();
    std::fs::create_dir_all(root.join("OPS")).unwrap();
    std::fs::write(root.join("META-INF/container.xml"), r#"<container><rootfiles><rootfile full-path='OPS/book.opf' media-type="application/oebps-package+xml"/></rootfiles></container>"#).unwrap();
    // Undeclared `xsi:` prefix and an HTML entity: invalid XML, still readable.
    std::fs::write(root.join("OPS/book.opf"), r#"<opf:package><metadata><dc:title xsi:type="x">书&nbsp;名</dc:title></metadata><manifest><opf:item id="a" href="a.html"/></manifest><spine><opf:itemref idref="a"/></spine></opf:package>"#).unwrap();
    std::fs::write(root.join("OPS/a.html"), "<h2>第一章 开端</h2><p>正文</p>").unwrap();
    let e = web::epub(&root, Limits::default()).unwrap();
    assert_eq!(e.text.lines().collect::<Vec<_>>(), vec!["第一章 开端", "正文"]);
    assert!(matches!(&e.anchors[0].kind, AnchorKind::Part { name } if name == "第一章 开端"));
}

#[test]
fn epub_with_wrong_entry_count_is_repaired() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("bad.epub");
    let mut z = zip::ZipWriter::new(std::fs::File::create(&p).unwrap());
    for (name, body) in [
        ("META-INF/container.xml", r#"<container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>"#),
        ("c.opf", r#"<package><manifest><item id="a" href="a.html"/></manifest><spine><itemref idref="a"/></spine></package>"#),
        ("a.html", "<p>修复后可读</p>"),
    ] {
        z.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
        z.write_all(body.as_bytes()).unwrap();
    }
    z.finish().unwrap();
    // Claim 9 entries where 3 exist, like the real files.
    let mut data = std::fs::read(&p).unwrap();
    let eocd = data.windows(4).rposition(|w| w == b"PK\x05\x06").unwrap();
    data[eocd + 8..eocd + 12].copy_from_slice(&[9, 0, 9, 0]);
    std::fs::write(&p, &data).unwrap();
    assert!(zip::ZipArchive::new(std::fs::File::open(&p).unwrap()).is_err());
    assert_eq!(web::epub(&p, Limits::default()).unwrap().text.trim(), "修复后可读");
}

#[test]
fn txt_chapters_zipped_as_epub() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("t.epub");
    let mut z = zip::ZipWriter::new(std::fs::File::create(&p).unwrap());
    for (name, body) in [("10.txt", "第十章 内容"), ("2.txt", "第二章\r\n\r\n内容")] {
        z.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
        z.write_all(body.as_bytes()).unwrap();
    }
    z.finish().unwrap();
    let e = web::epub(&p, Limits::default()).unwrap();
    assert_eq!((e.text.lines().collect::<Vec<_>>(), e.method.as_str()), (vec!["第二章", "内容", "第十章 内容"], "epub/loose"));
}
