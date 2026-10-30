//! Rust extractors (ARCHITECTURE §10). Each returns the display text exactly as it will be
//! stored and verified, plus anchors and a completeness state; nothing here is normalized.
use anyhow::{Context, Result, bail};
use std::{fs::File, io::Read, path::Path};
use xs_index::{Anchor, AnchorKind, ExtractState};

pub mod docx;
pub mod office;
pub mod web;

/// Bumped when an extractor's output can change for the same input bytes, so affected files
/// are re-extracted (§9.1 extractor_ver).
pub const TEXT_EXTRACTOR_VERSION: u64 = 1;
pub const DOCX_EXTRACTOR_VERSION: u64 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct Extraction {
    pub text: String,
    pub anchors: Vec<Anchor>,
    pub state: ExtractState,
    /// Human-readable reasons for `Partial` (shown in diagnostics; never contain file text).
    pub warnings: Vec<String>,
    /// e.g. "text/utf-8", "text/gb18030", "docx".
    pub method: String,
}

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Bytes of the source file read at most; beyond that the result is `Partial`.
    pub max_file_bytes: u64,
    /// Decompressed XML bytes per archive at most (zip bomb guard).
    pub max_unpacked_bytes: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_file_bytes: 100 * 1024 * 1024,
            max_unpacked_bytes: 256 * 1024 * 1024,
        }
    }
}

/// Plain text and source code. Encoding: BOM → valid UTF-8 → GB18030 (legacy Chinese files)
/// → lossy UTF-8 marked `Partial`. Binary files (NUL bytes outside UTF-16) are rejected.
pub fn plain_text(path: &Path, limits: Limits) -> Result<Extraction> {
    let file = File::open(path).with_context(|| "open failed")?;
    let len = file.metadata()?.len();
    let mut bytes = Vec::with_capacity(len.min(limits.max_file_bytes) as usize);
    file.take(limits.max_file_bytes).read_to_end(&mut bytes)?;
    let truncated = len > limits.max_file_bytes;
    let mut out = decode_text(&bytes, truncated)?;
    if truncated {
        out.state = ExtractState::Partial;
        out.warnings.push(format!(
            "超出单文件上限，只索引了前 {} MB",
            limits.max_file_bytes / (1024 * 1024)
        ));
    }
    Ok(out)
}

pub fn decode_text(bytes: &[u8], truncated: bool) -> Result<Extraction> {
    let done =
        |text: String, method: &str, state: ExtractState, warnings: Vec<String>| Extraction {
            text,
            anchors: vec![],
            state,
            warnings,
            method: format!("text/{method}"),
        };
    if let Some((enc, skip)) = encoding_rs::Encoding::for_bom(bytes) {
        let (text, _, bad) = enc.decode(&bytes[skip..]);
        let state = if bad {
            ExtractState::Partial
        } else {
            ExtractState::Complete
        };
        let warnings = if bad {
            vec!["部分字节无法解码".to_owned()]
        } else {
            vec![]
        };
        return Ok(done(text.into_owned(), enc.name(), state, warnings));
    }
    let head = &bytes[..bytes.len().min(8192)];
    if head.contains(&0) {
        bail!("binary file (NUL bytes)");
    }
    // A file cut at the size limit may end inside a multi-byte sequence: ignore that tail.
    let checked = if truncated {
        trim_partial_utf8(bytes)
    } else {
        bytes
    };
    if let Ok(s) = std::str::from_utf8(checked) {
        return Ok(done(s.to_owned(), "utf-8", ExtractState::Complete, vec![]));
    }
    let (text, bad) = encoding_rs::GB18030.decode_without_bom_handling(bytes);
    if !bad {
        return Ok(done(
            text.into_owned(),
            "gb18030",
            ExtractState::Complete,
            vec![],
        ));
    }
    let text = String::from_utf8_lossy(bytes).into_owned();
    Ok(done(
        text,
        "utf-8-lossy",
        ExtractState::Partial,
        vec!["编码无法识别，部分字符已替换".to_owned()],
    ))
}

fn trim_partial_utf8(b: &[u8]) -> &[u8] {
    // Drop at most 3 trailing bytes that form an incomplete sequence.
    for cut in 0..4.min(b.len() + 1) {
        let end = b.len() - cut;
        if std::str::from_utf8(&b[..end]).is_ok() {
            return &b[..end];
        }
    }
    b
}

/// Paragraph anchor helper shared by extractors that build text paragraph by paragraph.
pub(crate) fn paragraph_anchor(start: usize, index: u32) -> Anchor {
    Anchor {
        start: start as u32,
        kind: AnchorKind::Paragraph { index },
    }
}
