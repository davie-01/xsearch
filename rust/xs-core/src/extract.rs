use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::{fs::File, io::Read, ops::Range, path::Path};
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Anchor {
    pub source: String,
    pub paragraph: usize,
    pub range: Range<usize>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Extraction {
    pub text: String,
    pub anchors: Vec<Anchor>,
    pub complete: bool,
    pub warnings: Vec<String>,
}
pub fn text(bytes: &[u8], encoding: Option<&str>) -> Result<Extraction> {
    let (enc, skip) = if let Some((enc, skip)) = encoding_rs::Encoding::for_bom(bytes) {
        (enc, skip)
    } else {
        (
            encoding_rs::Encoding::for_label(encoding.unwrap_or("utf-8").as_bytes())
                .context("unknown encoding")?,
            0,
        )
    };
    let (text, _, bad) = enc.decode(&bytes[skip..]);
    if bad {
        bail!("decoding errors; select an explicit encoding")
    }
    Ok(Extraction {
        text: text.into_owned(),
        anchors: vec![],
        complete: true,
        warnings: vec![],
    })
}
pub fn docx(path: &Path) -> Result<Extraction> {
    const NS: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    if zip.len() > 10000 {
        bail!("archive entry limit")
    }
    let mut names = zip
        .file_names()
        .filter(|n| {
            *n == "word/document.xml"
                || n.starts_with("word/header")
                || n.starts_with("word/footer")
                || *n == "word/footnotes.xml"
                || *n == "word/endnotes.xml"
        })
        .map(str::to_string)
        .collect::<Vec<_>>();
    names.sort();
    if !names.iter().any(|n| n == "word/document.xml") {
        bail!("missing document.xml")
    }
    let mut out = Extraction {
        text: String::new(),
        anchors: vec![],
        complete: true,
        warnings: vec![],
    };
    let mut total = 0;
    for name in names {
        let mut f = zip.by_name(&name)?;
        total += f.size();
        if total > 64 * 1024 * 1024 {
            bail!("uncompressed XML limit")
        }
        let mut xml = String::new();
        Read::by_ref(&mut f)
            .take(64 * 1024 * 1024 + 1)
            .read_to_string(&mut xml)?;
        let doc = roxmltree::Document::parse(&xml)?;
        for (paragraph, p) in doc
            .descendants()
            .filter(|n| n.has_tag_name((NS, "p")))
            .enumerate()
        {
            let start = out.text.chars().count();
            // Only descendants owned by this paragraph: avoid duplicating text in nested text boxes.
            for n in p
                .descendants()
                .filter(|n| n.ancestors().skip(1).find(|a| a.has_tag_name((NS, "p"))) == Some(p))
            {
                if n.has_tag_name((NS, "t")) {
                    out.text.push_str(n.text().unwrap_or(""));
                } else if n.has_tag_name((NS, "tab")) {
                    out.text.push('\t');
                } else if n.has_tag_name((NS, "br")) {
                    out.text.push('\n');
                }
            }
            let end = out.text.chars().count();
            if end > start {
                out.anchors.push(Anchor {
                    source: name.clone(),
                    paragraph,
                    range: start..end,
                });
                out.text.push('\n');
            }
        }
    }
    Ok(out)
}
