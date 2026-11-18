use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tantivy::{
    Index, IndexSettings,
    schema::{FAST, Field, INDEXED, STORED, STRING, Schema},
    store::{Compressor, ZstdCompressor},
};
use xs_core::{normalize::NORM_VERSION, query::name_key};

/// Bumped whenever fields or their encoding change; an index with another version is rebuilt.
pub const SCHEMA_VERSION: &str = "xs-content-v1";
const META_FILE: &str = "xsearch-index.json";

/// Fields of ARCHITECTURE §8.5.
#[derive(Clone, Copy)]
pub struct Fields {
    pub file_id: Field,
    pub op_seq: Field,
    pub revision: Field,
    pub extractor_ver: Field,
    pub live: Field,
    pub scope: Field,
    /// Folded directory prefixes ("/", "/users", "/users/me", …): `dir:` is one term lookup,
    /// bounded at separators and case-insensitive like file names.
    pub dir_prefix: Field,
    pub dir: Field,
    pub name: Field,
    pub ext: Field,
    pub size: Field,
    pub mtime: Field,
    /// UTF-8 byte trigrams of the loose text plus the tagged trailing pair (§8.3).
    pub tri: Field,
    pub text: Field,
    pub anchors: Field,
    pub pages: Field,
    pub state: Field,
    pub source: Field,
    pub extract_key: Field,
}

pub fn schema() -> Schema {
    let mut b = Schema::builder();
    b.add_u64_field("file_id", INDEXED | FAST | STORED);
    b.add_u64_field("op_seq", FAST | STORED);
    b.add_u64_field("revision", STORED);
    b.add_u64_field("extractor_ver", STORED);
    b.add_u64_field("live", INDEXED | FAST);
    b.add_u64_field("scope", INDEXED);
    b.add_text_field("dir_prefix", STRING);
    b.add_text_field("dir", STORED);
    b.add_text_field("name", STORED);
    b.add_text_field("ext", STRING | STORED);
    b.add_i64_field("size", FAST | STORED);
    b.add_i64_field("mtime", FAST | STORED);
    b.add_u64_field("tri", INDEXED);
    b.add_text_field("display_text", STORED);
    b.add_bytes_field("anchors", STORED);
    b.add_bytes_field("pages", STORED);
    b.add_u64_field("extract_state", FAST | STORED);
    b.add_u64_field("source", STORED);
    b.add_text_field("extract_key", STRING | STORED);
    b.build()
}

impl Fields {
    pub fn of(s: &Schema) -> Result<Self> {
        Ok(Self {
            file_id: s.get_field("file_id")?,
            op_seq: s.get_field("op_seq")?,
            revision: s.get_field("revision")?,
            extractor_ver: s.get_field("extractor_ver")?,
            live: s.get_field("live")?,
            scope: s.get_field("scope")?,
            dir_prefix: s.get_field("dir_prefix")?,
            dir: s.get_field("dir")?,
            name: s.get_field("name")?,
            ext: s.get_field("ext")?,
            size: s.get_field("size")?,
            mtime: s.get_field("mtime")?,
            tri: s.get_field("tri")?,
            text: s.get_field("display_text")?,
            anchors: s.get_field("anchors")?,
            pages: s.get_field("pages")?,
            state: s.get_field("extract_state")?,
            source: s.get_field("source")?,
            extract_key: s.get_field("extract_key")?,
        })
    }
}

/// Sidecar identifying the index instance and the rules its terms were built with.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IndexMeta {
    pub schema: String,
    pub norm: String,
    pub instance_id: String,
}

/// Opens an existing index or creates one. Refuses an index built with another schema or
/// normalization version: its terms would silently miss matches (rebuild instead).
pub fn open_or_create(path: &Path, new_instance_id: &str) -> Result<(Index, IndexMeta)> {
    std::fs::create_dir_all(path)?;
    let meta_path = path.join(META_FILE);
    if path.join("meta.json").exists() {
        let meta: IndexMeta =
            serde_json::from_slice(&std::fs::read(&meta_path).context("index sidecar missing")?)?;
        ensure!(
            meta.schema == SCHEMA_VERSION,
            "index schema {} != {SCHEMA_VERSION}; rebuild required",
            meta.schema
        );
        ensure!(
            meta.norm == NORM_VERSION,
            "normalization {} != {NORM_VERSION}; rebuild required",
            meta.norm
        );
        let index = Index::open_in_dir(path)?;
        ensure!(
            index.schema() == schema(),
            "index fields differ from {SCHEMA_VERSION}; rebuild required"
        );
        return Ok((index, meta));
    }
    let settings = IndexSettings {
        // ARCHITECTURE §21 (M0-B): Zstd, 16 KB blocks (+ a doc store block cache on readers).
        docstore_compression: Compressor::Zstd(ZstdCompressor::default()),
        docstore_blocksize: 16_384,
        ..Default::default()
    };
    let index = Index::builder()
        .schema(schema())
        .settings(settings)
        .create_in_dir(path)?;
    let meta = IndexMeta {
        schema: SCHEMA_VERSION.into(),
        norm: NORM_VERSION.into(),
        instance_id: new_instance_id.into(),
    };
    std::fs::write(&meta_path, serde_json::to_vec(&meta)?)?;
    Ok((index, meta))
}

pub fn open_existing(path: &Path) -> Result<(Index, IndexMeta)> {
    ensure!(
        path.join("meta.json").exists(),
        "no content index at {}",
        path.display()
    );
    open_or_create(path, "")
}

/// "/" plus every folded ancestor prefix of an absolute directory.
pub fn dir_terms(dir: &str) -> Vec<String> {
    let mut out = vec!["/".to_owned()];
    let mut current = String::new();
    for c in dir.split('/').filter(|c| !c.is_empty()) {
        current.push('/');
        current.push_str(&name_key(c));
        out.push(current.clone());
    }
    out
}

/// The single term a `dir:` filter on `dir` looks up.
pub fn dir_term(dir: &str) -> String {
    dir_terms(dir).pop().unwrap_or_else(|| "/".into())
}

pub fn ext_of(name: &str) -> String {
    match name.rfind('.') {
        Some(i) if i > 0 && i + 1 < name.len() => name_key(&name[i + 1..]),
        _ => String::new(),
    }
}
