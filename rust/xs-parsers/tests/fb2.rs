use xs_index::{AnchorKind, ExtractState};
use xs_parsers::{Limits, fb2::fb2};

fn parts(e: &xs_parsers::Extraction) -> Vec<AnchorKind> {
    e.anchors.iter().map(|a| a.kind.clone()).filter(|k| matches!(k, AnchorKind::Part { .. })).collect()
}

fn part(name: &str) -> AnchorKind {
    AnchorKind::Part { name: name.into() }
}

#[test]
fn description_sections_notes_and_images() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("book.fb2");
    let xml = r##"<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
 <description><title-info><genre>prose</genre>
  <author><first-name>雪芹</first-name><last-name>曹</last-name></author><author><nickname>佚名</nickname></author>
  <book-title>红楼梦</book-title><annotation><p>一部<emphasis>长篇</emphasis>小说。</p></annotation><keywords>古典, 章回</keywords>
 </title-info><document-info><program-used>FB Editor</program-used></document-info></description>
 <body><title><p>红楼梦</p></title>
  <section><title><p>第一回</p><p>甄士隐梦幻识通灵</p></title><epigraph><p>满纸荒唐言</p><text-author>曹雪芹</text-author></epigraph>
   <p>此开卷第一回也<a l:href="#n1" type="note">[1]</a>。</p><image l:href="#cover.jpg"/>
   <poem><stanza><v>满纸荒唐言，</v><v>一把辛酸泪！</v></stanza></poem>
   <section><title><p>小节</p></title><p>嵌套段落</p></section></section>
  <section><p>无标题的一回</p><table><tr><th>人物</th><td>宝玉</td></tr></table></section>
 </body>
 <body name="notes"><section id="n1"><title><p>1</p></title><p>作者自云。</p></section></body>
 <binary id="cover.jpg" content-type="image/jpeg">/9j/4AAQSkZJRgABAQEASABIAAD</binary>
</FictionBook>"##;
    std::fs::write(&p, xml).unwrap();
    let e = fb2(&p, Limits::default()).unwrap();
    assert_eq!(
        e.text,
        "红楼梦\n雪芹 曹、佚名\n一部长篇小说。\n古典, 章回\n红楼梦\n第一回\n甄士隐梦幻识通灵\n满纸荒唐言\n曹雪芹\n此开卷第一回也[1]。\n\
满纸荒唐言，\n一把辛酸泪！\n小节\n嵌套段落\n无标题的一回\n人物\n宝玉\n1\n作者自云。\n"
    );
    assert!(!e.text.contains("9j"));
    assert_eq!(parts(&e), vec![part("简介"), part("第一回 甄士隐梦幻识通灵"), part("第 2 章"), part("注释")]);
    assert_eq!((e.state, e.method.as_str()), (ExtractState::Complete, "fb2"));
}

#[test]
fn legacy_encoding_and_malformed_files() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("ru.fb2");
    let xml = "<?xml version=\"1.0\" encoding=\"windows-1251\"?>\n<FictionBook><description><title-info><book-title>Война и мир</book-title></title-info></description>\
<body><section><title><p>Часть первая</p></title><p>Ну, князь.</p></section></body></FictionBook>";
    let (bytes, _, _) = encoding_rs::WINDOWS_1251.encode(xml);
    std::fs::write(&p, &bytes).unwrap();
    let e = fb2(&p, Limits::default()).unwrap();
    assert_eq!(e.text, "Война и мир\nЧасть первая\nНу, князь.\n");
    assert_eq!(parts(&e), vec![part("简介"), part("Часть первая")]);

    // An unclosed tag: read like HTML rather than failing.
    let bad = dir.path().join("bad.fb2");
    std::fs::write(&bad, "<FictionBook><body><section><p>未闭合 & 段落</section></body><binary id=\"x\">QUJD</binary></FictionBook>").unwrap();
    let e = fb2(&bad, Limits::default()).unwrap();
    assert_eq!((e.text.trim(), e.method.as_str()), ("未闭合 & 段落", "fb2/lenient"));

    let other = dir.path().join("note.fb2");
    std::fs::write(&other, "<html><body>不是电子书</body></html>").unwrap();
    assert!(fb2(&other, Limits::default()).is_err());
}
