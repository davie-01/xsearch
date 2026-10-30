//! Swift-facing API of the content engine (ARCHITECTURE §4: UniFFI). Readers live in the app
//! (QuerySession / PreviewController); the writer lives in IndexService. Errors carry a kind
//! so the UI can tell "rebuild the index" from "bad query".
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use xs_index as idx;

// The M1 C ABI (xs_name_key, …) lives in xs-core and is exported from this same static library.
pub use xs_core::ffi::{xs_name_key, xs_name_key_version, xs_normalize_utf8, xs_string_free};

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum EngineError {
    /// The query text could not be parsed (unbalanced quotes or parentheses…).
    Query {
        message: String,
    },
    /// The index was built with another schema or normalization version.
    Rebuild {
        message: String,
    },
    Index {
        message: String,
    },
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Query { message } | Self::Rebuild { message } | Self::Index { message } => {
                f.write_str(message)
            }
        }
    }
}

impl std::error::Error for EngineError {}

impl From<anyhow::Error> for EngineError {
    fn from(e: anyhow::Error) -> Self {
        let message = format!("{e:#}");
        if message.contains("rebuild") {
            Self::Rebuild { message }
        } else {
            Self::Index { message }
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum MatchMode {
    Loose,
    CaseSensitive,
    Strict,
}

impl From<MatchMode> for idx::Mode {
    fn from(m: MatchMode) -> Self {
        match m {
            MatchMode::Loose => Self::Loose,
            MatchMode::CaseSensitive => Self::CaseSensitive,
            MatchMode::Strict => Self::Strict,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum RecallKind {
    Trigram,
    Pair,
    LongTermsThenVerify,
    Scan,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum ExtractStateKind {
    Complete,
    Partial,
    WaitingOcr,
    Failed,
}

impl From<idx::ExtractState> for ExtractStateKind {
    fn from(s: idx::ExtractState) -> Self {
        match s {
            idx::ExtractState::Complete => Self::Complete,
            idx::ExtractState::Partial => Self::Partial,
            idx::ExtractState::WaitingOcr => Self::WaitingOcr,
            idx::ExtractState::Failed => Self::Failed,
        }
    }
}

impl From<ExtractStateKind> for idx::ExtractState {
    fn from(s: ExtractStateKind) -> Self {
        match s {
            ExtractStateKind::Complete => Self::Complete,
            ExtractStateKind::Partial => Self::Partial,
            ExtractStateKind::WaitingOcr => Self::WaitingOcr,
            ExtractStateKind::Failed => Self::Failed,
        }
    }
}

/// Half-open range in UTF-16 code units (NSString / NSRange offsets).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Utf16Range {
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ContentHit {
    pub file_id: u64,
    pub name: String,
    pub dir: String,
    pub mtime: i64,
    pub size: i64,
    pub state: ExtractStateKind,
    pub hit_count: u32,
    pub snippet: String,
    pub snippet_highlights: Vec<Utf16Range>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ContentBatch {
    pub hits: Vec<ContentHit>,
    pub candidates: u64,
    pub verified: u64,
    pub done: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchFilters {
    pub dirs: Vec<String>,
    pub exts: Vec<String>,
    pub scopes: Vec<u64>,
}

/// Stored document for the preview. Anchors and page states are JSON (`xs_index::Anchor`,
/// `PageState`), decoded on the Swift side.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ContentDocument {
    pub file_id: u64,
    pub op_seq: u64,
    pub revision: u64,
    pub name: String,
    pub dir: String,
    pub mtime: i64,
    pub size: i64,
    pub text: String,
    pub anchors_json: String,
    pub pages_json: String,
    pub state: ExtractStateKind,
}

fn parse(query: &str) -> Result<idx::Expr, EngineError> {
    idx::parse(query).map_err(|e| EngineError::Query {
        message: e.to_string(),
    })
}

fn range(r: std::ops::Range<u32>) -> Utf16Range {
    Utf16Range {
        start: r.start,
        end: r.end,
    }
}

/// Read side. Cheap to share; every `search` pins its own snapshot.
#[derive(uniffi::Object)]
pub struct ContentIndex {
    reader: idx::ContentReader,
}

#[uniffi::export]
impl ContentIndex {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, EngineError> {
        Ok(Arc::new(Self {
            reader: idx::ContentReader::open(Path::new(&path))?,
        }))
    }

    /// Picks up commits made since the last reload (also happens automatically shortly after).
    pub fn reload(&self) -> Result<(), EngineError> {
        Ok(self.reader.reload()?)
    }

    pub fn live_count(&self) -> Result<u64, EngineError> {
        Ok(self.reader.live_count()? as u64)
    }

    /// Starts a query over the current snapshot. `query` uses the content syntax: spaces = AND,
    /// `|` = OR, leading `-` = NOT, quotes and parentheses.
    pub fn search(
        &self,
        query: String,
        mode: MatchMode,
        filters: SearchFilters,
    ) -> Result<Arc<ContentSearch>, EngineError> {
        let req = idx::SearchRequest {
            expr: parse(&query)?,
            mode: mode.into(),
            dirs: filters.dirs,
            exts: filters.exts,
            scopes: filters.scopes,
        };
        let session = self.reader.session(req)?;
        let recall = match session.recall {
            idx::Recall::Trigram => RecallKind::Trigram,
            idx::Recall::Pair => RecallKind::Pair,
            idx::Recall::LongTermsThenVerify => RecallKind::LongTermsThenVerify,
            idx::Recall::Scan => RecallKind::Scan,
        };
        let candidates = session.candidates() as u64;
        Ok(Arc::new(ContentSearch {
            session: Mutex::new(session),
            cancelled: AtomicBool::new(false),
            recall,
            candidates,
        }))
    }

    pub fn document(&self, file_id: u64) -> Result<Option<ContentDocument>, EngineError> {
        Ok(self.reader.document(file_id)?.map(|d| ContentDocument {
            file_id: d.file_id,
            op_seq: d.op_seq,
            revision: d.revision,
            name: d.name,
            dir: d.dir,
            mtime: d.mtime,
            size: d.size,
            text: d.text,
            anchors_json: serde_json::to_string(&d.anchors).unwrap_or_else(|_| "[]".into()),
            pages_json: serde_json::to_string(&d.pages).unwrap_or_else(|_| "[]".into()),
            state: d.state.into(),
        }))
    }

    /// All hits of `query` in one file, as UTF-16 ranges of its stored text.
    pub fn highlights(
        &self,
        file_id: u64,
        query: String,
        mode: MatchMode,
    ) -> Result<Vec<Utf16Range>, EngineError> {
        Ok(self
            .reader
            .highlights(file_id, &parse(&query)?, mode.into())?
            .into_iter()
            .map(range)
            .collect())
    }
}

/// One running query. `next` may be called repeatedly from a background queue; `cancel` from
/// any thread stops the current and later calls.
#[derive(uniffi::Object)]
pub struct ContentSearch {
    session: Mutex<idx::SearchSession>,
    cancelled: AtomicBool,
    recall: RecallKind,
    candidates: u64,
}

#[uniffi::export]
impl ContentSearch {
    pub fn recall(&self) -> RecallKind {
        self.recall
    }

    pub fn candidates(&self) -> u64 {
        self.candidates
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    pub fn next(&self, budget_ms: u32, max_hits: u32) -> Result<ContentBatch, EngineError> {
        let mut session = self.session.lock().map_err(|_| EngineError::Index {
            message: "search session poisoned".into(),
        })?;
        let b = session.next(
            Duration::from_millis(budget_ms as u64),
            max_hits.max(1) as usize,
            &self.cancelled,
        )?;
        Ok(ContentBatch {
            hits: b
                .hits
                .into_iter()
                .map(|h| ContentHit {
                    file_id: h.file_id,
                    name: h.name,
                    dir: h.dir,
                    mtime: h.mtime,
                    size: h.size,
                    state: h.state.into(),
                    hit_count: h.hit_count,
                    snippet: h.snippet,
                    snippet_highlights: h.snippet_highlights.into_iter().map(range).collect(),
                })
                .collect(),
            candidates: b.candidates as u64,
            verified: b.verified as u64,
            done: b.done,
        })
    }
}

/// Input for the writer. `anchors_json` / `pages_json` follow `xs_index::Anchor` / `PageState`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ContentInput {
    pub file_id: u64,
    pub op_seq: u64,
    pub revision: u64,
    pub extractor_ver: u64,
    pub scope_ids: Vec<u64>,
    pub dir: String,
    pub name: String,
    pub size: i64,
    pub mtime: i64,
    pub text: String,
    pub anchors_json: String,
    pub pages_json: String,
    pub state: ExtractStateKind,
    pub extract_key: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CommitRecord {
    pub instance_id: String,
    pub batch_id: u64,
}

/// Write side; exactly one per index instance (IndexService).
#[derive(uniffi::Object)]
pub struct ContentIndexWriter {
    writer: Mutex<idx::ContentWriter>,
}

impl ContentIndexWriter {
    fn with<T>(
        &self,
        f: impl FnOnce(&mut idx::ContentWriter) -> anyhow::Result<T>,
    ) -> Result<T, EngineError> {
        let mut w = self.writer.lock().map_err(|_| EngineError::Index {
            message: "writer poisoned".into(),
        })?;
        Ok(f(&mut w)?)
    }
}

#[uniffi::export]
impl ContentIndexWriter {
    #[uniffi::constructor]
    pub fn open(path: String, new_instance_id: String) -> Result<Arc<Self>, EngineError> {
        Ok(Arc::new(Self {
            writer: Mutex::new(idx::ContentWriter::open(
                Path::new(&path),
                &new_instance_id,
            )?),
        }))
    }

    pub fn instance_id(&self) -> Result<String, EngineError> {
        self.with(|w| Ok(w.instance_id.clone()))
    }

    pub fn put(&self, doc: ContentInput) -> Result<(), EngineError> {
        let d = idx::ContentDoc {
            file_id: doc.file_id,
            op_seq: doc.op_seq,
            revision: doc.revision,
            extractor_ver: doc.extractor_ver,
            scope_ids: doc.scope_ids,
            dir: doc.dir,
            name: doc.name,
            size: doc.size,
            mtime: doc.mtime,
            text: doc.text,
            anchors: serde_json::from_str(&doc.anchors_json).map_err(|e| EngineError::Index {
                message: format!("anchors: {e}"),
            })?,
            pages: serde_json::from_str(&doc.pages_json).map_err(|e| EngineError::Index {
                message: format!("pages: {e}"),
            })?,
            state: doc.state.into(),
            source: idx::Source::Text,
            extract_key: doc.extract_key,
        };
        self.with(|w| w.put(&d))
    }

    pub fn remove(&self, file_id: u64, op_seq: u64) -> Result<(), EngineError> {
        self.with(|w| w.remove(file_id, op_seq))
    }

    pub fn commit(&self, batch_id: u64) -> Result<(), EngineError> {
        self.with(|w| w.commit(batch_id))
    }

    pub fn rollback(&self) -> Result<(), EngineError> {
        self.with(|w| w.rollback())
    }

    pub fn last_commit(&self) -> Result<Option<CommitRecord>, EngineError> {
        self.with(|w| {
            Ok(w.last_commit()?.map(|c| CommitRecord {
                instance_id: c.instance_id,
                batch_id: c.batch_id,
            }))
        })
    }

    pub fn applied_seqs(&self) -> Result<HashMap<u64, u64>, EngineError> {
        self.with(|w| w.applied_seqs())
    }

    /// Committed document with this extraction cache key, for reuse without re-extracting.
    pub fn find_by_extract_key(&self, key: String) -> Result<Option<ContentDocument>, EngineError> {
        self.with(|w| {
            Ok(w.find_by_extract_key(&key)?.map(|d| ContentDocument {
                file_id: d.file_id,
                op_seq: d.op_seq,
                revision: d.revision,
                name: d.name,
                dir: d.dir,
                mtime: d.mtime,
                size: d.size,
                text: d.text,
                anchors_json: serde_json::to_string(&d.anchors).unwrap_or_else(|_| "[]".into()),
                pages_json: serde_json::to_string(&d.pages).unwrap_or_else(|_| "[]".into()),
                state: d.state.into(),
            }))
        })
    }

    pub fn garbage_collect(&self) -> Result<(), EngineError> {
        self.with(|w| w.garbage_collect())
    }
}

/// Result of a Rust extractor. Anchors / pages are JSON in the `xs_index` formats.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ExtractionOutput {
    pub text: String,
    pub anchors_json: String,
    pub pages_json: String,
    pub state: ExtractStateKind,
    pub warnings: Vec<String>,
    pub method: String,
    pub extractor_ver: u64,
}

fn output(e: xs_parsers::Extraction, extractor_ver: u64) -> ExtractionOutput {
    ExtractionOutput {
        text: e.text,
        anchors_json: serde_json::to_string(&e.anchors).unwrap_or_else(|_| "[]".into()),
        pages_json: "[]".into(),
        state: e.state.into(),
        warnings: e.warnings,
        method: e.method,
        extractor_ver,
    }
}

fn limits(max_file_bytes: u64, max_unpacked_bytes: u64) -> xs_parsers::Limits {
    xs_parsers::Limits {
        max_file_bytes,
        max_unpacked_bytes,
    }
}

/// Plain text / source code with encoding detection; binary files are an error.
#[uniffi::export]
pub fn extract_plain_text(
    path: String,
    max_file_bytes: u64,
) -> Result<ExtractionOutput, EngineError> {
    let e = xs_parsers::plain_text(Path::new(&path), limits(max_file_bytes, max_file_bytes))?;
    Ok(output(e, xs_parsers::TEXT_EXTRACTOR_VERSION))
}

#[uniffi::export]
pub fn extract_docx(
    path: String,
    max_unpacked_bytes: u64,
) -> Result<ExtractionOutput, EngineError> {
    let e = xs_parsers::docx::extract(Path::new(&path), limits(u64::MAX, max_unpacked_bytes))?;
    Ok(output(e, xs_parsers::DOCX_EXTRACTOR_VERSION))
}

#[uniffi::export]
pub fn extract_spreadsheet(path: String, max_unpacked_bytes: u64) -> Result<ExtractionOutput, EngineError> {
    let e = xs_parsers::office::spreadsheet(Path::new(&path), limits(u64::MAX, max_unpacked_bytes))?;
    Ok(output(e, xs_parsers::office::SHEET_EXTRACTOR_VERSION))
}

#[uniffi::export]
pub fn extract_pptx(path: String, max_unpacked_bytes: u64) -> Result<ExtractionOutput, EngineError> {
    let e = xs_parsers::office::pptx(Path::new(&path), limits(u64::MAX, max_unpacked_bytes))?;
    Ok(output(e, xs_parsers::office::PPTX_EXTRACTOR_VERSION))
}

#[uniffi::export]
pub fn extract_ofd(path: String, max_unpacked_bytes: u64) -> Result<ExtractionOutput, EngineError> {
    let e = xs_parsers::office::ofd(Path::new(&path), limits(u64::MAX, max_unpacked_bytes))?;
    Ok(output(e, xs_parsers::office::OFD_EXTRACTOR_VERSION))
}

/// Engine versions, for diagnostics and rebuild decisions.
#[uniffi::export]
pub fn engine_versions() -> HashMap<String, String> {
    HashMap::from([
        ("schema".to_owned(), idx::schema::SCHEMA_VERSION.to_owned()),
        (
            "normalization".to_owned(),
            xs_core::normalize::NORM_VERSION.to_owned(),
        ),
        (
            "extractor.text".to_owned(),
            xs_parsers::TEXT_EXTRACTOR_VERSION.to_string(),
        ),
        (
            "extractor.docx".to_owned(),
            xs_parsers::DOCX_EXTRACTOR_VERSION.to_string(),
        ),
        ("extractor.sheet".to_owned(), xs_parsers::office::SHEET_EXTRACTOR_VERSION.to_string()),
        ("extractor.slide".to_owned(), xs_parsers::office::PPTX_EXTRACTOR_VERSION.to_string()),
        ("extractor.ofd".to_owned(), xs_parsers::office::OFD_EXTRACTOR_VERSION.to_string()),
    ])
}
