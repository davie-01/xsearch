use xs_index::{AnchorKind, ExtractState};
use xs_parsers::{Limits, email::email};

fn parts(e: &xs_parsers::Extraction) -> Vec<AnchorKind> {
    e.anchors.iter().map(|a| a.kind.clone()).filter(|k| matches!(k, AnchorKind::Part { .. })).collect()
}

fn part(name: &str) -> AnchorKind {
    AnchorKind::Part { name: name.into() }
}

#[test]
fn multipart_with_gbk_subject_and_attachment() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("notice.eml");
    let raw = "From: =?UTF-8?B?5byg5LiJ?= <zhang@example.com>\r\n\
To: li@example.com, Wang <wang@example.com>, zhao@example.com <zhao@example.com>\r\n\
Subject: =?GBK?B?udjT2tHpytW1xM2o1qo=?=\r\n\
Date: Tue, 18 Nov 2026 14:20:00 +0800\r\n\
MIME-Version: 1.0\r\n\
Content-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n\
--outer\r\n\
Content-Type: multipart/alternative; boundary=\"alt\"\r\n\r\n\
--alt\r\n\
Content-Type: text/plain; charset=utf-8\r\n\r\n\
支付条件：终验后 30 日内支付。\r\n\
--alt\r\n\
Content-Type: text/html; charset=utf-8\r\n\r\n\
<p>支付条件：<b>终验后</b> 30 日内支付。</p>\r\n\
--alt--\r\n\
--outer\r\n\
Content-Type: application/pdf; name=\"=?UTF-8?B?5ZCI5ZCM5omr5o+P5Lu2LnBkZg==?=\"\r\n\
Content-Disposition: attachment\r\n\
Content-Transfer-Encoding: base64\r\n\r\n\
JVBERi0xLjQK\r\n\
--outer--\r\n";
    std::fs::write(&p, raw).unwrap();
    let e = email(&p, Limits::default()).unwrap();
    assert_eq!(
        e.text,
        "主题：关于验收的通知\n发件人：张三 <zhang@example.com>\n收件人：li@example.com, Wang <wang@example.com>, zhao@example.com\n\
日期：2026-11-18 14:20\n支付条件：终验后 30 日内支付。\n附件：合同扫描件.pdf\n"
    );
    assert_eq!(parts(&e), vec![part("邮件头"), part("正文"), part("附件")]);
    assert_eq!((e.state, e.method.as_str()), (ExtractState::Complete, "email"));
}

#[test]
fn html_only_and_emlx() {
    let dir = tempfile::tempdir().unwrap();
    let msg = "Subject: Weekly report\r\nFrom: a@example.com\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body><h1>进度</h1><p>完成 80%</p></body></html>\r\n";
    // Apple Mail: the byte count, the message, then a property list that is not part of it.
    let emlx = format!("{}\n{msg}<?xml version=\"1.0\"?><plist><dict><key>flags</key></dict></plist>", msg.len());
    let p = dir.path().join("1234.emlx");
    std::fs::write(&p, emlx).unwrap();
    let e = email(&p, Limits::default()).unwrap();
    assert_eq!(e.text, "主题：Weekly report\n发件人：a@example.com\n进度\n完成 80%\n");
    assert!(!e.text.contains("plist"));
    assert!(e.anchors.iter().any(|a| a.kind == AnchorKind::Paragraph { index: 2 }));

    let bad = dir.path().join("empty.eml");
    std::fs::write(&bad, "").unwrap();
    assert!(email(&bad, Limits::default()).is_err());
}
