//! M3 formats: spreadsheets (XLSX / XLSM / XLS / ODS via calamine), PPTX and OFD.
use crate::{Extraction, Limits};
use anyhow::{Context, Result, bail};
use calamine::{Data, Reader, open_workbook_auto};
use roxmltree::Node;
use std::{collections::BTreeMap, fs::File, io::Read, path::Path};
use xs_index::{Anchor, AnchorKind, ExtractState};

pub const SHEET_EXTRACTOR_VERSION: u64 = 1;
pub const PPTX_EXTRACTOR_VERSION: u64 = 1;
pub const OFD_EXTRACTOR_VERSION: u64 = 2;

pub(crate) struct Out {
    pub(crate) text: String,
    pub(crate) chars: usize,
    pub(crate) anchors: Vec<Anchor>,
    pub(crate) partial: bool,
    pub(crate) warnings: Vec<String>,
    max_chars: usize,
}

impl Out {
    pub(crate) fn new(limits: Limits) -> Self {
        // Unpacked byte budget doubles as a text budget (scalars ≤ bytes).
        Self { text: String::new(), chars: 0, anchors: vec![], partial: false, warnings: vec![], max_chars: limits.max_unpacked_bytes as usize }
    }
    pub(crate) fn anchor(&mut self, kind: AnchorKind) {
        self.anchors.push(Anchor { start: self.chars as u32, kind });
    }
    /// Returns false once the text budget is exhausted.
    pub(crate) fn push(&mut self, s: &str) -> bool {
        if self.chars >= self.max_chars {
            if !self.partial {
                self.partial = true;
                self.warnings.push("内容超过上限，后续部分未索引".into());
            }
            return false;
        }
        self.text.push_str(s);
        self.chars += s.chars().count();
        true
    }
    pub(crate) fn done(self, method: &str) -> Extraction {
        Extraction {
            text: self.text,
            anchors: self.anchors,
            state: if self.partial { ExtractState::Partial } else { ExtractState::Complete },
            warnings: self.warnings,
            method: method.into(),
        }
    }
}

fn column(mut i: usize) -> String {
    let mut s = String::new();
    loop {
        s.insert(0, (b'A' + (i % 26) as u8) as char);
        if i < 26 {
            return s;
        }
        i = i / 26 - 1;
    }
}

/// One line per non-empty row (cells separated by tabs), anchored "Sheet1!A12" at the row's
/// first non-empty cell. Formulas contribute their cached values.
pub fn spreadsheet(path: &Path, limits: Limits) -> Result<Extraction> {
    // Known extensions pick their reader; others (WPS .et = BIFF8) are recognised by content.
    let known = path.extension().and_then(|e| e.to_str()).is_some_and(|e| {
        ["xlsx", "xlsm", "xlsb", "xls", "xla", "ods"].contains(&e.to_ascii_lowercase().as_str())
    });
    let mut wb = if known {
        open_workbook_auto(path).context("spreadsheet unreadable")?
    } else {
        let data = std::fs::read(path)?;
        let auto = calamine::open_workbook_auto_from_rs(std::io::Cursor::new(data)).context("spreadsheet unreadable")?;
        return sheets_into(auto, limits);
    };
    sheets_into_impl(&mut wb, limits)
}

fn sheets_into<RS: std::io::Read + std::io::Seek>(mut wb: calamine::Sheets<RS>, limits: Limits) -> Result<Extraction> {
    sheets_into_impl(&mut wb, limits)
}

fn sheets_into_impl<RS: std::io::Read + std::io::Seek>(wb: &mut calamine::Sheets<RS>, limits: Limits) -> Result<Extraction> {
    let mut out = Out::new(limits);
    'sheets: for name in wb.sheet_names().to_owned() {
        let Ok(range) = wb.worksheet_range(&name) else { continue };
        let (r0, c0) = range.start().unwrap_or((0, 0));
        for (r, row) in range.rows().enumerate() {
            let cells: Vec<(usize, String)> = row
                .iter()
                .enumerate()
                .filter_map(|(c, v)| {
                    let s = match v {
                        Data::Empty => return None,
                        Data::String(s) => s.clone(),
                        Data::Float(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", *f as i64),
                        other => other.to_string(),
                    };
                    let s = s.trim().to_owned();
                    (!s.is_empty()).then_some((c, s))
                })
                .collect();
            let Some((first, _)) = cells.first() else { continue };
            out.anchor(AnchorKind::Sheet { sheet: name.clone(), cell: format!("{}{}", column(c0 as usize + first), r0 as usize + r + 1) });
            let line = cells.into_iter().map(|(_, s)| s).collect::<Vec<_>>().join("\t");
            if !out.push(&line) || !out.push("\n") {
                break 'sheets;
            }
        }
    }
    Ok(out.done("sheet"))
}

pub(crate) fn zip_text<R: Read + std::io::Seek>(zip: &mut zip::ZipArchive<R>, name: &str, limits: Limits, used: &mut u64) -> Result<String> {
    let mut f = zip.by_name(name)?;
    *used += f.size();
    if *used > limits.max_unpacked_bytes {
        bail!("uncompressed size limit");
    }
    let mut s = String::new();
    Read::by_ref(&mut f).take(limits.max_unpacked_bytes + 1).read_to_string(&mut s)?;
    Ok(s)
}

/// Numbered parts in numeric order: slide2 before slide10.
fn numbered(zip: &zip::ZipArchive<File>, prefix: &str) -> BTreeMap<u32, String> {
    zip.file_names()
        .filter_map(|n| {
            let num = n.strip_prefix(prefix)?.strip_suffix(".xml")?.parse().ok()?;
            Some((num, n.to_owned()))
        })
        .collect()
}

const A: &str = "http://schemas.openxmlformats.org/drawingml/2006/main";

/// Paragraph texts (`a:p` → `a:t` runs, `a:br` breaks) of a DrawingML part.
fn drawing_paragraphs(xml: &str) -> Result<Vec<String>> {
    let doc = roxmltree::Document::parse(xml)?;
    Ok(doc
        .descendants()
        .filter(|n| n.has_tag_name((A, "p")))
        .map(|p| {
            let mut s = String::new();
            for n in p.descendants() {
                if n.has_tag_name((A, "t")) {
                    s.push_str(n.text().unwrap_or(""));
                } else if n.has_tag_name((A, "br")) {
                    s.push('\n');
                }
            }
            s
        })
        .filter(|s| !s.trim().is_empty())
        .collect())
}

/// Slides in order, each followed by its speaker notes; a slide anchor per slide. Binary
/// PowerPoint (.ppt / .pps, WPS .dps) is recognised by its OLE2 signature.
pub fn pptx(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut magic = [0u8; 8];
    if File::open(path)?.read_exact(&mut magic).is_ok() && magic == OLE_MAGIC {
        return ppt_binary(path, limits);
    }
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    let slides = numbered(&zip, "ppt/slides/slide");
    if slides.is_empty() {
        bail!("no slides");
    }
    let notes = numbered(&zip, "ppt/notesSlides/notesSlide");
    let mut out = Out::new(limits);
    let mut used = 0;
    for (n, name) in slides {
        out.anchor(AnchorKind::Slide { slide: n });
        for p in drawing_paragraphs(&zip_text(&mut zip, &name, limits, &mut used)?)? {
            out.push(&p);
            out.push("\n");
        }
        // Notes numbering follows slides in typical files; good enough for search.
        if let Some(note) = notes.get(&n) {
            let paras = drawing_paragraphs(&zip_text(&mut zip, note, limits, &mut used)?)?;
            // The first note paragraphs often repeat the slide number placeholder; keep text only.
            let paras: Vec<_> = paras.into_iter().filter(|p| p.trim().parse::<u32>().is_err()).collect();
            if !paras.is_empty() {
                out.anchor(AnchorKind::Part { name: format!("备注 {n}") });
                for p in paras {
                    out.push(&p);
                    out.push("\n");
                }
            }
        }
        if out.partial {
            break;
        }
    }
    Ok(out.done("pptx"))
}

fn local(n: &Node, name: &str) -> bool {
    n.is_element() && n.tag_name().name() == name
}

pub(crate) fn join(base: &str, rel: &str) -> String {
    let rel = rel.trim_start_matches('/');
    let mut parts: Vec<&str> = base.split('/').filter(|s| !s.is_empty()).collect();
    for seg in rel.split('/') {
        match seg {
            "." | "" => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

/// OFD (GB/T 33190): OFD.xml → DocRoot (Document.xml) → Pages in order → Content.xml; text is
/// `TextCode` inside `TextObject`, one line per text object, a page anchor per page.
pub fn ofd(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    let mut used = 0;
    let root_xml = zip_text(&mut zip, "OFD.xml", limits, &mut used).context("missing OFD.xml")?;
    let root = roxmltree::Document::parse(&root_xml)?;
    let doc_root = root.descendants().find(|n| local(n, "DocRoot")).and_then(|n| n.text()).context("missing DocRoot")?.trim().to_owned();
    let doc_dir = doc_root.rsplit_once('/').map(|(d, _)| d.to_owned()).unwrap_or_default();
    let doc_xml = zip_text(&mut zip, &join("", &doc_root), limits, &mut used)?;
    let doc = roxmltree::Document::parse(&doc_xml)?;
    let mut pages: Vec<String> = doc
        .descendants()
        .filter(|n| local(n, "Page"))
        .filter_map(|n| n.attribute("BaseLoc"))
        .map(|loc| join(&doc_dir, loc))
        .collect();
    if pages.is_empty() {
        // Fallback: every page content file in numeric order.
        let mut found: Vec<(u32, String)> = zip
            .file_names()
            .filter(|n| n.ends_with("/Content.xml") && n.contains("/Pages/"))
            .filter_map(|n| {
                let page = n.split('/').find(|s| s.starts_with("Page_"))?.trim_start_matches("Page_").parse().ok()?;
                Some((page, n.to_owned()))
            })
            .collect();
        found.sort();
        pages = found.into_iter().map(|(_, n)| n).collect();
    }
    let mut out = Out::new(limits);
    let mut image_only = 0;
    for (i, page) in pages.iter().enumerate() {
        out.anchor(AnchorKind::Page { page: i as u32 + 1 });
        let Ok(xml) = zip_text(&mut zip, page, limits, &mut used) else {
            out.partial = true;
            out.warnings.push(format!("第 {} 页无法读取", i + 1));
            continue;
        };
        let content = roxmltree::Document::parse(&xml)?;
        let before = out.chars;
        for obj in content.descendants().filter(|n| local(n, "TextObject")) {
            let line: String = obj.descendants().filter(|n| local(n, "TextCode")).filter_map(|n| n.text()).collect();
            if !line.trim().is_empty() {
                out.push(&line);
                out.push("\n");
            }
        }
        // Scanned pages: images and no text layer (OCR is M6).
        if out.chars == before && content.descendants().any(|n| local(&n, "ImageObject")) {
            image_only += 1;
        }
        if out.partial {
            break;
        }
    }
    let pages_total = pages.len();
    let mut e = out.done("ofd");
    if image_only > 0 {
        e.warnings.push(format!("{image_only} 页没有文字层，等待 OCR"));
        if image_only == pages_total {
            e.state = ExtractState::WaitingOcr;
        } else if e.state == ExtractState::Complete {
            e.state = ExtractState::Partial;
        }
    }
    Ok(e)
}

/// Archive reader: memory-backed when the file needed repair.
pub(crate) type AnyZip = zip::ZipArchive<Box<dyn ReadSeek>>;
pub(crate) trait ReadSeek: Read + std::io::Seek {}
impl<T: Read + std::io::Seek> ReadSeek for T {}

/// Opens a zip; when the end-of-central-directory record claims the wrong number of entries
/// (seen in real ePubs from buggy writers; Python accepts them, the zip crate does not), the
/// file is read into memory with the count corrected from the actual central directory.
pub(crate) fn open_zip(path: &Path, limits: Limits) -> Result<AnyZip> {
    let first = zip::ZipArchive::new(Box::new(File::open(path)?) as Box<dyn ReadSeek>);
    let Err(err) = first else { return Ok(first?) };
    let size = std::fs::metadata(path)?.len();
    if size > limits.max_unpacked_bytes.max(limits.max_file_bytes) {
        return Err(err.into());
    }
    let mut data = std::fs::read(path)?;
    let Some(eocd) = data.windows(4).rposition(|w| w == b"PK\x05\x06") else { return Err(err.into()) };
    if eocd + 22 > data.len() {
        return Err(err.into());
    }
    let u32_at = |d: &[u8], o: usize| u32::from_le_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]]) as usize;
    let (cd_size, cd_off) = (u32_at(&data, eocd + 12), u32_at(&data, eocd + 16));
    if cd_off + cd_size > eocd {
        return Err(err.into());
    }
    // Walk the central directory headers that really exist.
    let mut count = 0u16;
    let mut at = cd_off;
    while at + 46 <= cd_off + cd_size && data[at..at + 4] == *b"PK\x01\x02" {
        let len = |o: usize| u16::from_le_bytes([data[at + o], data[at + o + 1]]) as usize;
        at += 46 + len(28) + len(30) + len(32);
        count += 1;
    }
    if count == 0 {
        return Err(err.into());
    }
    data[eocd + 8..eocd + 10].copy_from_slice(&count.to_le_bytes());
    data[eocd + 10..eocd + 12].copy_from_slice(&count.to_le_bytes());
    Ok(zip::ZipArchive::new(Box::new(std::io::Cursor::new(data)) as Box<dyn ReadSeek>)?)
}

pub(crate) const OLE_MAGIC: [u8; 8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

/// Text of a binary PowerPoint 97–2003 deck ([MS-PPT]). Primary path: `ppt_by_persist`.
/// Fallback for files without a usable persist directory: a plain walk of the record tree that
/// assigns text boxes to slides in container order (title / notes masters can then shift
/// numbering).
fn ppt_binary(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut ole = cfb::open(path).context("not an OLE2 file")?;
    let mut stream = ole.open_stream("/PowerPoint Document").context("missing PowerPoint Document stream")?;
    let mut data = vec![];
    Read::by_ref(&mut stream).take(limits.max_unpacked_bytes).read_to_end(&mut data)?;

    #[derive(Default)]
    struct Walk {
        slides: BTreeMap<u32, Vec<String>>,
        notes: BTreeMap<u32, Vec<String>>,
        list: Option<u16>,
        slide: u32,
        note: u32,
        container: Option<u32>,
        containers: u32,
        notes_container: Option<u32>,
        notes_containers: u32,
    }
    fn add(map: &mut BTreeMap<u32, Vec<String>>, n: u32, text: String) {
        let t = text.replace(['\r', '\u{0B}'], "\n");
        let t = t.trim();
        if t.is_empty() || n == 0 {
            return;
        }
        let v = map.entry(n).or_default();
        if !v.iter().any(|x| x == t) {
            v.push(t.to_owned());
        }
    }
    fn walk(d: &[u8], w: &mut Walk, depth: u32) {
        let mut pos = 0;
        while pos + 8 <= d.len() && depth < 32 {
            let verinst = u16::from_le_bytes([d[pos], d[pos + 1]]);
            let rtype = u16::from_le_bytes([d[pos + 2], d[pos + 3]]);
            let len = u32::from_le_bytes([d[pos + 4], d[pos + 5], d[pos + 6], d[pos + 7]]) as usize;
            let body = &d[pos + 8..(pos + 8).saturating_add(len).min(d.len())];
            pos = (pos + 8).saturating_add(len);
            let (ver, inst) = (verinst & 0xF, verinst >> 4);
            let text = match rtype {
                0x0FA0 => Some(String::from_utf16_lossy(&body.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect::<Vec<_>>())),
                0x0FA8 => Some(body.iter().map(|&b| b as char).collect()),
                _ => None,
            };
            if let Some(t) = text {
                if let Some(c) = w.container {
                    add(&mut w.slides, c, t);
                } else if let Some(c) = w.notes_container {
                    add(&mut w.notes, c, t);
                } else if w.list == Some(0) {
                    add(&mut w.slides, w.slide, t);
                } else if w.list == Some(2) {
                    add(&mut w.notes, w.note, t);
                }
                continue;
            }
            match rtype {
                0x03F8 | 0x0FD9 | 0x0FC4 => {}
                0x0FF0 => {
                    w.list = Some(inst);
                    walk(body, w, depth + 1);
                    w.list = None;
                }
                0x03F3 => match w.list {
                    Some(0) => w.slide += 1,
                    Some(2) => w.note += 1,
                    _ => {}
                },
                0x03EE => {
                    w.containers += 1;
                    w.container = Some(w.containers);
                    walk(body, w, depth + 1);
                    w.container = None;
                }
                0x03F0 => {
                    w.notes_containers += 1;
                    w.notes_container = Some(w.notes_containers);
                    walk(body, w, depth + 1);
                    w.notes_container = None;
                }
                _ if ver == 0xF => walk(body, w, depth + 1),
                _ => {}
            }
        }
    }
    let mut w = Walk::default();
    if !ppt_by_persist(&data, &mut w.slides, &mut w.notes) {
        walk(&data, &mut w, 0);
    }
    let mut out = Out::new(limits);
    let numbers: std::collections::BTreeSet<u32> = w.slides.keys().chain(w.notes.keys()).copied().collect();
    for n in numbers {
        out.anchor(AnchorKind::Slide { slide: n });
        for t in w.slides.get(&n).into_iter().flatten() {
            out.push(t);
            out.push("\n");
        }
        // Slide-number fields and similar one-word placeholders are left out of notes.
        let notes: Vec<&String> = w.notes.get(&n).into_iter().flatten().filter(|t| t.trim().parse::<u32>().is_err()).collect();
        if !notes.is_empty() {
            out.anchor(AnchorKind::Part { name: format!("备注 {n}") });
            for t in notes {
                out.push(t);
                out.push("\n");
            }
        }
        if out.partial {
            break;
        }
    }
    Ok(out.done("ppt"))
}

struct Rec<'a> {
    ver: u16,
    inst: u16,
    rtype: u16,
    body: &'a [u8],
    end: usize,
}

fn rec_at(d: &[u8], pos: usize) -> Option<Rec<'_>> {
    if pos + 8 > d.len() {
        return None;
    }
    let verinst = u16::from_le_bytes([d[pos], d[pos + 1]]);
    let rtype = u16::from_le_bytes([d[pos + 2], d[pos + 3]]);
    let len = u32::from_le_bytes([d[pos + 4], d[pos + 5], d[pos + 6], d[pos + 7]]) as usize;
    let end = (pos + 8).saturating_add(len).min(d.len());
    Some(Rec { ver: verinst & 0xF, inst: verinst >> 4, rtype, body: &d[pos + 8..end], end })
}

fn atom_text(r: &Rec) -> Option<String> {
    match r.rtype {
        0x0FA0 => Some(String::from_utf16_lossy(&r.body.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect::<Vec<_>>())),
        0x0FA8 => Some(r.body.iter().map(|&b| b as char).collect()),
        _ => None,
    }
}

/// Every text atom inside a container, depth-first.
fn texts_in(d: &[u8], out: &mut Vec<String>, depth: u32) {
    let mut pos = 0;
    while let Some(r) = rec_at(d, pos) {
        pos = pos + 8 + r.body.len();
        if let Some(t) = atom_text(&r) {
            out.push(t);
        } else if r.ver == 0xF && depth < 32 {
            texts_in(r.body, out, depth + 1);
        }
    }
}

/// [MS-PPT] structure: the persist directory (0x1772, later entries win) maps persist ids to
/// stream offsets; the newest DocumentContainer's SlideListWithText lists slides (instance 0)
/// and notes (instance 2) in order, each SlidePersistAtom carrying persistIdRef (+0) and
/// slideId (+12) followed by its placeholder text; a slide's container holds its text boxes
/// and a SlideAtom (0x03EF) whose notesIdRef (+16) names its notes. Masters are never
/// referenced, so their template text stays out. Returns false when the structure is missing.
fn ppt_by_persist(d: &[u8], slides: &mut BTreeMap<u32, Vec<String>>, notes: &mut BTreeMap<u32, Vec<String>>) -> bool {
    let u32_at = |b: &[u8], o: usize| (o + 4 <= b.len()).then(|| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]));
    let mut persist: std::collections::HashMap<u32, usize> = Default::default();
    let mut doc: Option<usize> = None;
    let mut pos = 0;
    while let Some(r) = rec_at(d, pos) {
        match r.rtype {
            0x1772 => {
                let mut o = 0;
                while let Some(h) = u32_at(r.body, o) {
                    let (start, count) = (h & 0xF_FFFF, (h >> 20) as usize);
                    for k in 0..count {
                        if let Some(off) = u32_at(r.body, o + 4 + 4 * k) {
                            persist.insert(start + k as u32, off as usize);
                        }
                    }
                    o += 4 + 4 * count;
                }
            }
            0x03E8 => doc = Some(pos),
            _ => {}
        }
        pos = r.end;
    }
    let Some(doc) = doc.and_then(|p| rec_at(d, p)) else { return false };
    struct Entry {
        persist: u32,
        id: u32,
        texts: Vec<String>,
    }
    let (mut slide_list, mut notes_list) = (vec![], vec![]);
    let mut p = 0;
    while let Some(r) = rec_at(doc.body, p) {
        p = r.end;
        if r.rtype != 0x0FF0 || (r.inst != 0 && r.inst != 2) {
            continue;
        }
        let list: &mut Vec<Entry> = if r.inst == 0 { &mut slide_list } else { &mut notes_list };
        let mut q = 0;
        while let Some(c) = rec_at(r.body, q) {
            q = c.end;
            if c.rtype == 0x03F3 {
                list.push(Entry { persist: u32_at(c.body, 0).unwrap_or(0), id: u32_at(c.body, 12).unwrap_or(0), texts: vec![] });
            } else if let (Some(t), Some(e)) = (atom_text(&c), list.last_mut()) {
                e.texts.push(t);
            } else if c.ver == 0xF && let Some(e) = list.last_mut() {
                texts_in(c.body, &mut e.texts, 1);
            }
        }
    }
    if slide_list.is_empty() {
        return false;
    }
    let container = |persist_id: u32| persist.get(&persist_id).and_then(|&o| rec_at(d, o)).filter(|r| r.rtype == 0x03EE || r.rtype == 0x03F0);
    let notes_by_id: std::collections::HashMap<u32, &Entry> = notes_list.iter().map(|e| (e.id, e)).collect();
    let push = |map: &mut BTreeMap<u32, Vec<String>>, n: u32, t: &str| {
        let t = t.replace(['\r', '\u{0B}'], "\n");
        let t = t.trim();
        if t.is_empty() {
            return;
        }
        let v = map.entry(n).or_default();
        if !v.iter().any(|x| x == t) {
            v.push(t.to_owned());
        }
    };
    for (i, s) in slide_list.iter().enumerate() {
        let n = i as u32 + 1;
        slides.entry(n).or_default();
        s.texts.iter().for_each(|t| push(slides, n, t));
        let Some(c) = container(s.persist) else { continue };
        let mut boxes = vec![];
        texts_in(c.body, &mut boxes, 1);
        boxes.iter().for_each(|t| push(slides, n, t));
        // SlideAtom → notesIdRef → notes entry (list text + notes container text boxes).
        let notes_id = {
            let mut q = 0;
            let mut found = None;
            while let Some(a) = rec_at(c.body, q) {
                q = a.end;
                if a.rtype == 0x03EF {
                    found = u32_at(a.body, 16);
                    break;
                }
            }
            found
        };
        if let Some(e) = notes_id.filter(|&id| id != 0).and_then(|id| notes_by_id.get(&id)) {
            e.texts.iter().for_each(|t| push(notes, n, t));
            if let Some(nc) = container(e.persist) {
                let mut nb = vec![];
                texts_in(nc.body, &mut nb, 1);
                nb.iter().for_each(|t| push(notes, n, t));
            }
        }
    }
    slides.retain(|_, v| !v.is_empty());
    true
}
