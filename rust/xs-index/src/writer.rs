use crate::{
    doc::ContentDoc,
    schema::{Fields, dir_terms, ext_of, open_or_create},
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::Path};
use tantivy::{
    Index, IndexReader, IndexWriter, ReloadPolicy, TantivyDocument, Term, schema::Value,
};
use xs_core::{
    index::byte_grams,
    normalize::{Mode, normalize_text},
};

/// What the last successful commit recorded (§9.3: instance and batch ids in the payload).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CommitInfo {
    pub instance_id: String,
    pub batch_id: u64,
}

/// The only writer of an index instance (lives in IndexService). Not thread-safe by design.
pub struct ContentWriter {
    index: Index,
    writer: IndexWriter,
    reader: IndexReader,
    f: Fields,
    pub instance_id: String,
}

impl ContentWriter {
    /// Opens the index at `path`; a new index gets `new_instance_id`.
    pub fn open(path: &Path, new_instance_id: &str) -> Result<Self> {
        let (index, meta) = open_or_create(path, new_instance_id)?;
        let f = Fields::of(&index.schema())?;
        let writer = index.writer_with_num_threads(1, 50_000_000)?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;
        Ok(Self {
            index,
            writer,
            reader,
            f,
            instance_id: meta.instance_id,
        })
    }

    /// Replaces the file's document (delete by file_id + add); visible after `commit`.
    pub fn put(&mut self, d: &ContentDoc) -> Result<()> {
        let f = self.f;
        self.writer
            .delete_term(Term::from_field_u64(f.file_id, d.file_id));
        let mut doc = TantivyDocument::default();
        doc.add_u64(f.file_id, d.file_id);
        doc.add_u64(f.op_seq, d.op_seq);
        doc.add_u64(f.revision, d.revision);
        doc.add_u64(f.extractor_ver, d.extractor_ver);
        doc.add_u64(f.live, 1);
        for s in &d.scope_ids {
            doc.add_u64(f.scope, *s);
        }
        for t in dir_terms(&d.dir) {
            doc.add_text(f.dir_prefix, t);
        }
        doc.add_text(f.dir, &d.dir);
        doc.add_text(f.name, &d.name);
        doc.add_text(f.ext, ext_of(&d.name));
        doc.add_i64(f.size, d.size);
        doc.add_i64(f.mtime, d.mtime);
        for g in byte_grams(&normalize_text(&d.text, Mode::Loose)) {
            doc.add_u64(f.tri, g);
        }
        doc.add_text(f.text, &d.text);
        doc.add_bytes(f.anchors, &serde_json::to_vec(&d.anchors)?);
        doc.add_bytes(f.pages, &serde_json::to_vec(&d.pages)?);
        doc.add_u64(f.state, d.state.code());
        doc.add_u64(f.source, d.source as u64);
        doc.add_text(f.extract_key, &d.extract_key);
        self.writer.add_document(doc)?;
        Ok(())
    }

    /// Removes the file's content but keeps a minimal tombstone with its op_seq, so the sequence
    /// fence survives restarts (§9.3). Tombstones hold no text, anchors or names.
    pub fn remove(&mut self, file_id: u64, op_seq: u64) -> Result<()> {
        let f = self.f;
        self.writer
            .delete_term(Term::from_field_u64(f.file_id, file_id));
        let mut doc = TantivyDocument::default();
        doc.add_u64(f.file_id, file_id);
        doc.add_u64(f.op_seq, op_seq);
        doc.add_u64(f.live, 0);
        self.writer.add_document(doc)?;
        Ok(())
    }

    /// Commits everything staged since the last commit, recording instance and batch.
    pub fn commit(&mut self, batch_id: u64) -> Result<()> {
        let payload = serde_json::to_string(&CommitInfo {
            instance_id: self.instance_id.clone(),
            batch_id,
        })?;
        let mut prepared = self.writer.prepare_commit()?;
        prepared.set_payload(&payload);
        prepared.commit()?;
        self.reader.reload()?;
        Ok(())
    }

    /// Drops everything staged since the last commit.
    pub fn rollback(&mut self) -> Result<()> {
        self.writer.rollback()?;
        self.reader.reload()?;
        Ok(())
    }

    pub fn last_commit(&self) -> Result<Option<CommitInfo>> {
        Ok(match self.index.load_metas()?.payload {
            Some(p) => Some(serde_json::from_str(&p)?),
            None => None,
        })
    }

    /// file_id → op_seq of every committed document, tombstones included: the writer's
    /// persisted sequence table after a restart (§9.3).
    pub fn applied_seqs(&self) -> Result<HashMap<u64, u64>> {
        let searcher = self.reader.searcher();
        let mut out = HashMap::new();
        for seg in searcher.segment_readers() {
            let ids = seg.fast_fields().u64("file_id")?;
            let seqs = seg.fast_fields().u64("op_seq")?;
            for doc in seg.doc_ids_alive() {
                if let (Some(id), Some(seq)) = (ids.first(doc), seqs.first(doc)) {
                    out.insert(id, seq);
                }
            }
        }
        Ok(out)
    }

    /// Committed text of one file (tests and diagnostics).
    pub fn committed_text(&self, file_id: u64) -> Result<Option<String>> {
        let searcher = self.reader.searcher();
        let q = tantivy::query::TermQuery::new(
            Term::from_field_u64(self.f.file_id, file_id),
            tantivy::schema::IndexRecordOption::Basic,
        );
        let found = searcher.search(&q, &tantivy::collector::DocSetCollector)?;
        ensure!(found.len() <= 1, "duplicate documents for file {file_id}");
        Ok(match found.into_iter().next() {
            Some(a) => searcher
                .doc::<TantivyDocument>(a)?
                .get_first(self.f.text)
                .and_then(|v| v.as_str())
                .map(str::to_owned),
            None => None,
        })
    }

    /// Reclaims files no longer referenced by any commit (§6.2: disk space is reclaimed later
    /// than query-level deletion, and only once old searchers are gone).
    pub fn garbage_collect(&mut self) -> Result<()> {
        let _ = self.writer.garbage_collect_files().wait();
        Ok(())
    }
}
