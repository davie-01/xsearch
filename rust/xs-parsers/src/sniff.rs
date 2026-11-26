//! The real format of a file from its first bytes, for files whose extension lies: Word 97
//! documents saved as .docx, Excel 2003 XML or "single file web page" saved as .xls, an
//! OOXML package under an old extension, an encrypted OOXML document (an OLE container holding
//! `EncryptedPackage`). Only a positive identification is returned; anything else is left to
//! the extension.
use std::{fs::File, io::Read, path::Path};

/// Bumped when detection recognises more: files that failed are then tried again.
pub const SNIFF_VERSION: u64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sniffed {
    /// OLE container with a `WordDocument` stream.
    Word97,
    /// OLE container with a `Workbook` (BIFF8) or `Book` (BIFF5) stream.
    OleWorkbook,
    /// OLE container with a `PowerPoint Document` stream.
    OlePowerPoint,
    /// OLE container with an `EncryptedPackage` stream: a password-protected OOXML file.
    OleEncrypted,
    Docx,
    Xlsx,
    Xlsb,
    Pptx,
    Pdf,
    Rtf,
    Html,
    /// Excel 2003 XML spreadsheet (`<?mso-application progid="Excel.Sheet"?>`).
    ExcelXml,
    /// MHTML ("single file web page"): a MIME multipart/related message.
    WebArchive,
}

impl Sniffed {
    pub fn code(self) -> &'static str {
        match self {
            Self::Word97 => "word97",
            Self::OleWorkbook => "ole_workbook",
            Self::OlePowerPoint => "ole_powerpoint",
            Self::OleEncrypted => "ole_encrypted",
            Self::Docx => "docx",
            Self::Xlsx => "xlsx",
            Self::Xlsb => "xlsb",
            Self::Pptx => "pptx",
            Self::Pdf => "pdf",
            Self::Rtf => "rtf",
            Self::Html => "html",
            Self::ExcelXml => "excel_xml",
            Self::WebArchive => "web_archive",
        }
    }
}

pub(crate) const ZIP_MAGIC: [u8; 4] = *b"PK\x03\x04";

pub fn sniff(path: &Path) -> Option<Sniffed> {
    let mut head = Vec::with_capacity(4096);
    File::open(path).ok()?.take(4096).read_to_end(&mut head).ok()?;
    if head.starts_with(&crate::office::OLE_MAGIC) {
        return ole(path);
    }
    if head.starts_with(&ZIP_MAGIC) {
        return package(path);
    }
    if head.starts_with(b"%PDF-") {
        return Some(Sniffed::Pdf);
    }
    if head.starts_with(b"{\\rtf") {
        return Some(Sniffed::Rtf);
    }
    let text = trimmed_start(&head);
    let lower = String::from_utf8_lossy(&text[..text.len().min(4096)]).to_ascii_lowercase();
    if lower.starts_with("mime-version:") && lower.contains("multipart/related") {
        return Some(Sniffed::WebArchive);
    }
    if lower.starts_with("<?xml") {
        return (lower.contains("progid=\"excel.sheet\"") || lower.contains("urn:schemas-microsoft-com:office:spreadsheet"))
            .then_some(Sniffed::ExcelXml);
    }
    if lower.starts_with("<!doctype html") || lower.starts_with("<html") || lower.starts_with("<table") {
        return Some(Sniffed::Html);
    }
    None
}

/// Without a UTF-8 BOM and leading whitespace.
fn trimmed_start(b: &[u8]) -> &[u8] {
    let b = b.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(b);
    let start = b.iter().position(|c| !c.is_ascii_whitespace()).unwrap_or(b.len());
    &b[start..]
}

fn ole(path: &Path) -> Option<Sniffed> {
    // Some writers (AppKit among them) produce containers the cfb crate refuses; their stream
    // names are still in the first directory sector.
    let names = match cfb::open(path) {
        Ok(c) => c.read_root_storage().map(|e| e.name().to_owned()).collect(),
        Err(_) => first_directory_names(path)?,
    };
    let has = |name: &str| names.iter().any(|n: &String| n == name.trim_start_matches('/'));
    if has("/EncryptedPackage") {
        Some(Sniffed::OleEncrypted)
    } else if has("/WordDocument") {
        Some(Sniffed::Word97)
    } else if has("/Workbook") || has("/Book") {
        Some(Sniffed::OleWorkbook)
    } else if has("/PowerPoint Document") {
        Some(Sniffed::OlePowerPoint)
    } else {
        None
    }
}

/// Entry names in the directory sector the header points to ([MS-CFB] 2.2, 2.6.1).
fn first_directory_names(path: &Path) -> Option<Vec<String>> {
    use std::io::{Seek, SeekFrom};
    let mut f = File::open(path).ok()?;
    let mut header = [0u8; 512];
    f.read_exact(&mut header).ok()?;
    let shift = u16::from_le_bytes([header[0x1E], header[0x1F]]);
    if shift != 9 && shift != 12 {
        return None;
    }
    let size = 1u64 << shift;
    let first = u32::from_le_bytes(header[0x30..0x34].try_into().ok()?) as u64;
    f.seek(SeekFrom::Start((first + 1) * size)).ok()?;
    let mut sector = vec![0u8; size as usize];
    f.read_exact(&mut sector).ok()?;
    Some(
        sector
            .as_chunks::<128>()
            .0
            .iter()
            .filter_map(|e| {
                let len = (u16::from_le_bytes([e[0x40], e[0x41]]) as usize).min(64);
                let units: Vec<u16> = e[..len.saturating_sub(2)].as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect();
                (!units.is_empty()).then(|| String::from_utf16_lossy(&units))
            })
            .collect(),
    )
}

fn package(path: &Path) -> Option<Sniffed> {
    let z = zip::ZipArchive::new(File::open(path).ok()?).ok()?;
    let has = |name: &str| z.index_for_name(name).is_some();
    if has("word/document.xml") {
        Some(Sniffed::Docx)
    } else if has("xl/workbook.xml") {
        Some(Sniffed::Xlsx)
    } else if has("xl/workbook.bin") {
        Some(Sniffed::Xlsb)
    } else if has("ppt/presentation.xml") {
        Some(Sniffed::Pptx)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn file(dir: &tempfile::TempDir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let p = dir.path().join(name);
        std::fs::write(&p, bytes).unwrap();
        p
    }

    fn ole_with(dir: &tempfile::TempDir, name: &str, stream: &str) -> std::path::PathBuf {
        let p = dir.path().join(name);
        let mut c = cfb::create(&p).unwrap();
        c.create_stream(stream).unwrap().write_all(b"x").unwrap();
        c.flush().unwrap();
        p
    }

    fn zip_with(dir: &tempfile::TempDir, name: &str, member: &str) -> std::path::PathBuf {
        let p = dir.path().join(name);
        let mut z = zip::ZipWriter::new(File::create(&p).unwrap());
        z.start_file(member, zip::write::SimpleFileOptions::default()).unwrap();
        z.write_all(b"<x/>").unwrap();
        z.finish().unwrap();
        p
    }

    #[test]
    fn containers_by_content() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(sniff(&ole_with(&d, "a.docx", "/WordDocument")), Some(Sniffed::Word97));
        assert_eq!(sniff(&ole_with(&d, "b.xlsx", "/Workbook")), Some(Sniffed::OleWorkbook));
        assert_eq!(sniff(&ole_with(&d, "c.xls", "/Book")), Some(Sniffed::OleWorkbook));
        assert_eq!(sniff(&ole_with(&d, "d.pptx", "/PowerPoint Document")), Some(Sniffed::OlePowerPoint));
        assert_eq!(sniff(&ole_with(&d, "e.docx", "/EncryptedPackage")), Some(Sniffed::OleEncrypted));
        assert_eq!(sniff(&ole_with(&d, "f.doc", "/Other")), None);
        assert_eq!(sniff(&zip_with(&d, "g.xls", "xl/workbook.xml")), Some(Sniffed::Xlsx));
        assert_eq!(sniff(&zip_with(&d, "h.doc", "word/document.xml")), Some(Sniffed::Docx));
        assert_eq!(sniff(&zip_with(&d, "i.ppt", "ppt/presentation.xml")), Some(Sniffed::Pptx));
        assert_eq!(sniff(&zip_with(&d, "j.odt", "content.xml")), None);
    }

    #[test]
    fn text_formats_by_content() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(sniff(&file(&d, "a.doc", b"%PDF-1.7\n")), Some(Sniffed::Pdf));
        assert_eq!(sniff(&file(&d, "b.doc", b"{\\rtf1\\ansi x}")), Some(Sniffed::Rtf));
        assert_eq!(sniff(&file(&d, "c.xls", b"\xEF\xBB\xBF\r\n<HTML xmlns:o=\"x\">")), Some(Sniffed::Html));
        let xml = b"<?xml version=\"1.0\"?>\n<?mso-application progid=\"Excel.Sheet\"?>\n<Workbook/>";
        assert_eq!(sniff(&file(&d, "d.xls", xml)), Some(Sniffed::ExcelXml));
        assert_eq!(sniff(&file(&d, "e.xls", b"<?xml version=\"1.0\"?><other/>")), None);
        let mht = b"MIME-Version: 1.0\r\nContent-Type: multipart/related; boundary=\"b\"\r\n";
        assert_eq!(sniff(&file(&d, "f.xls", mht)), Some(Sniffed::WebArchive));
        assert_eq!(sniff(&file(&d, "g.docx", b"\x05admin      ")), None);
    }
}
