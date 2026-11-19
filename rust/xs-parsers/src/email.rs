//! E-mail messages: .eml (RFC 5322 / MIME) and Apple Mail's .emlx (the same with a byte count
//! line before it and a property list after). The header fields people search by, then the
//! body (plain text, or the HTML part read like a web page), then the attachments' names;
//! attachments themselves are not read yet.
//! Anchors: parts "邮件头", "正文", "附件"; HTML bodies add paragraph anchors.
use crate::office::Out;
use crate::{Extraction, Limits};
use anyhow::{Result, anyhow};
use mail_parser::{Address, MessageParser, MimeHeaders, PartType};
use std::{fs::File, io::Read, path::Path};
use xs_index::{AnchorKind, ExtractState};

pub const EMAIL_EXTRACTOR_VERSION: u64 = 1;

pub fn email(path: &Path, limits: Limits) -> Result<Extraction> {
    let file = File::open(path)?;
    let len = file.metadata()?.len();
    let mut bytes = vec![];
    file.take(limits.max_file_bytes).read_to_end(&mut bytes)?;
    let truncated = len > limits.max_file_bytes;
    let raw = if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("emlx")) { emlx_message(&bytes) } else { &bytes[..] };
    let msg = MessageParser::default().parse(raw).ok_or_else(|| anyhow!("not an e-mail message"))?;

    let mut out = Out::new(limits);
    out.anchor(AnchorKind::Part { name: "邮件头".into() });
    let mut header = |label: &str, value: Option<String>| {
        if let Some(v) = value.filter(|v| !v.trim().is_empty()) {
            out.push(&format!("{label}：{}\n", v.trim()));
        }
    };
    header("主题", msg.subject().map(str::to_owned));
    header("发件人", msg.from().map(addresses));
    header("收件人", msg.to().map(addresses));
    header("抄送", msg.cc().map(addresses));
    header("日期", msg.date().map(|d| format!("{:04}-{:02}-{:02} {:02}:{:02}", d.year, d.month, d.day, d.hour, d.minute)));

    let mut started = false;
    let mut para = 0;
    for part in msg.text_bodies() {
        if !started {
            out.anchor(AnchorKind::Part { name: "正文".into() });
            started = true;
        }
        match &part.body {
            PartType::Text(t) => {
                out.push(t.trim_end());
                out.push("\n");
            }
            PartType::Html(h) => crate::web::html_into(h, &mut out, &mut para),
            _ => {}
        }
        if out.partial {
            break;
        }
    }
    let names: Vec<_> = msg.attachments().filter_map(|a| a.attachment_name()).filter(|n| !n.trim().is_empty()).collect();
    if !names.is_empty() {
        out.anchor(AnchorKind::Part { name: "附件".into() });
        out.push(&format!("附件：{}\n", names.join("、")));
    }
    let mut e = out.done("email");
    if truncated {
        e.state = ExtractState::Partial;
        e.warnings.push(format!("超出单文件上限，只索引了前 {} MB", limits.max_file_bytes / (1024 * 1024)));
    }
    Ok(e)
}

/// "Name <address>, …" (the name alone when there is no address, the address alone when there
/// is no name or the name only repeats it).
fn addresses(a: &Address) -> String {
    a.iter()
        .map(|x| match (x.name(), x.address()) {
            (Some(n), Some(m)) if !n.is_empty() && n != m => format!("{n} <{m}>"),
            (_, Some(m)) => m.to_owned(),
            (Some(n), None) => n.to_owned(),
            (None, None) => String::new(),
        })
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(", ")
}

/// .emlx: a decimal byte count on the first line, then that many bytes of message.
fn emlx_message(bytes: &[u8]) -> &[u8] {
    let Some(nl) = bytes.iter().position(|&b| b == b'\n') else { return bytes };
    let count = std::str::from_utf8(&bytes[..nl]).ok().and_then(|s| s.trim().parse::<usize>().ok());
    let rest = &bytes[nl + 1..];
    match count {
        Some(n) => &rest[..n.min(rest.len())],
        None => bytes,
    }
}
