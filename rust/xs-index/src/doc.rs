use serde::{Deserialize, Serialize};

/// Extraction completeness of a document or page (§14: OCR reservations from M2 on).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ExtractState {
    #[default]
    Complete,
    /// Text exists but is known to be incomplete (size limits, NUL / replacement characters).
    Partial,
    /// No text layer; waiting for OCR (M6).
    WaitingOcr,
    Failed,
}

impl ExtractState {
    pub fn code(self) -> u64 {
        match self {
            Self::Complete => 0,
            Self::Partial => 1,
            Self::WaitingOcr => 2,
            Self::Failed => 3,
        }
    }
    pub fn from_code(c: u64) -> Self {
        match c {
            1 => Self::Partial,
            2 => Self::WaitingOcr,
            3 => Self::Failed,
            _ => Self::Complete,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    #[default]
    Text,
    Ocr,
    Both,
}

/// Where a run of text came from, for "PDF 第 14 页" / "段 13" / "表 2·B3" labels and for
/// mapping a hit back into the original file. OCR boxes are reserved for M6 (§11.1, §14).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AnchorKind {
    Page {
        page: u32,
    },
    Paragraph {
        index: u32,
    },
    Cell {
        table: u32,
        cell: String,
    },
    Line {
        line: u32,
    },
    Part {
        name: String,
    },
    OcrBox {
        page: u32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
}

/// An anchor starts at a Unicode scalar offset of the display text and runs to the next one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Anchor {
    pub start: u32,
    #[serde(flatten)]
    pub kind: AnchorKind,
}

/// Per-page extraction record: mixed PDFs have text pages and scanned pages (§14 item 2).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PageState {
    pub page: u32,
    pub source: Source,
    pub state: ExtractState,
    pub extractor_ver: u64,
    pub config: String,
}

/// Everything the writer stores for one file. Each file keeps its own text and anchors (D9).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ContentDoc {
    pub file_id: u64,
    /// Catalog op_seq this document reflects; older results are rejected by the writer protocol.
    pub op_seq: u64,
    pub revision: u64,
    pub extractor_ver: u64,
    pub scope_ids: Vec<u64>,
    /// Absolute directory path of the file.
    pub dir: String,
    pub name: String,
    pub size: i64,
    pub mtime: i64,
    pub text: String,
    pub anchors: Vec<Anchor>,
    pub pages: Vec<PageState>,
    pub state: ExtractState,
    pub source: Source,
    /// Extraction cache key (strong digest + extractor version + config, §10).
    pub extract_key: String,
}
