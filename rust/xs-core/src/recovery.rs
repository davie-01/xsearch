//! M0 protocol harness backed by real SQLite/WAL and real Tantivy commits.
//! Source text in SQLite is synthetic harness input, not the production FileCatalog schema.
use crate::index::{Engine, GramKind};
use anyhow::{Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_secs()
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    pub instance: String,
    pub file: u64,
    pub seq: u64,
    pub lease: u64,
    pub text: Option<String>,
}
#[derive(Debug, Serialize, Deserialize)]
struct Batch {
    instance: String,
    batch: u64,
    jobs: Vec<Job>,
}
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Fault {
    None,
    BeforeCommit,
    AfterCommitBeforeAck,
    AmbiguousCommitted,
    AmbiguousNotCommitted,
    BeforeCutover,
    AfterCutover,
}
pub struct Coordinator {
    pub db: Connection,
    pub engines: BTreeMap<String, Engine>,
    root: PathBuf,
    applied: BTreeMap<String, BTreeMap<u64, u64>>,
    staged: BTreeMap<String, Vec<Job>>,
    blocked: BTreeSet<String>,
}
impl Coordinator {
    pub fn open(root: &Path) -> Result<Self> {
        std::fs::create_dir_all(root)?;
        let db = Connection::open(root.join("catalog.sqlite"))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS catalog(id INTEGER PRIMARY KEY,seq INTEGER NOT NULL,text TEXT);
        CREATE TABLE IF NOT EXISTS operations(jseq INTEGER PRIMARY KEY AUTOINCREMENT,file INTEGER,seq INTEGER,kind TEXT);
        CREATE TABLE IF NOT EXISTS instances(id TEXT PRIMARY KEY,role TEXT,start INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT);
        CREATE TABLE IF NOT EXISTS jobs(instance TEXT,file INTEGER,seq INTEGER,lease INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL DEFAULT 'pending',text TEXT,lease_until INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(instance,file,seq));
        CREATE TABLE IF NOT EXISTS receipts(instance TEXT,batch INTEGER,PRIMARY KEY(instance,batch));
        CREATE TABLE IF NOT EXISTS cursors(consumer TEXT PRIMARY KEY,seq INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS name_snapshot(file INTEGER PRIMARY KEY,seq INTEGER NOT NULL);
        INSERT OR IGNORE INTO cursors VALUES('source',0),('name',0),('content:initial',0);
        INSERT OR IGNORE INTO instances VALUES('initial','active',0);
        INSERT OR IGNORE INTO meta VALUES('active','initial');")?;
        let ids = db
            .prepare("SELECT id FROM instances WHERE role IN ('active','building')")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut out = Self {
            db,
            engines: BTreeMap::new(),
            root: root.into(),
            applied: BTreeMap::new(),
            staged: BTreeMap::new(),
            blocked: BTreeSet::new(),
        };
        for id in ids {
            let e = Engine::open(&root.join(&id), GramKind::Byte, false)?;
            out.applied.insert(id.clone(), e.applied()?);
            out.engines.insert(id.clone(), e);
            out.recover(&id)?;
        }
        Ok(out)
    }
    pub fn active(&self) -> Result<String> {
        Ok(self
            .db
            .query_row("SELECT value FROM meta WHERE key='active'", [], |r| {
                r.get(0)
            })?)
    }
    pub fn event(&mut self, file: u64, text: Option<&str>, kind: &str) -> Result<u64> {
        let tx = self.db.transaction()?;
        let seq = tx
            .query_row("SELECT seq FROM catalog WHERE id=?", [file], |r| {
                r.get::<_, u64>(0)
            })
            .optional()?
            .unwrap_or(0)
            + 1;
        tx.execute("INSERT INTO catalog VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET seq=excluded.seq,text=excluded.text",params![file,seq,text])?;
        tx.execute(
            "INSERT INTO operations(file,seq,kind) VALUES(?,?,?)",
            params![file, seq, kind],
        )?;
        tx.execute("INSERT INTO jobs(instance,file,seq,text) SELECT id,?,?,? FROM instances WHERE role IN ('active','building')",params![file,seq,text])?;
        // Source event acknowledgement and durable downstream work share one SQLite transaction.
        tx.execute(
            "UPDATE cursors SET seq=(SELECT MAX(jseq) FROM operations) WHERE consumer='source'",
            [],
        )?;
        tx.execute("INSERT INTO cursors SELECT 'content:'||id,(SELECT MAX(jseq) FROM operations) FROM instances WHERE role IN ('active','building') ON CONFLICT(consumer) DO UPDATE SET seq=excluded.seq",[])?;
        tx.commit()?;
        Ok(seq)
    }
    pub fn claim(&mut self, instance: &str, file: u64, seq: u64) -> Result<Job> {
        let updated=self.db.execute("UPDATE jobs SET lease=lease+1,status='leased',lease_until=? WHERE instance=? AND file=? AND seq=? AND (status='pending' OR (status='leased' AND lease_until<=?))",params![now()+30,instance,file,seq,now()])?;
        if updated != 1 {
            bail!("job already leased, acknowledged or superseded")
        }
        Ok(self.db.query_row(
            "SELECT lease,text FROM jobs WHERE instance=? AND file=? AND seq=?",
            params![instance, file, seq],
            |r| {
                Ok(Job {
                    instance: instance.into(),
                    file,
                    seq,
                    lease: r.get(0)?,
                    text: r.get(1)?,
                })
            },
        )?)
    }
    fn admissible(&self, j: &Job) -> Result<bool> {
        // Harness coordinator owns catalog mutations and write admission on this serialized lane.
        let role = self
            .db
            .query_row(
                "SELECT role FROM instances WHERE id=?",
                [&j.instance],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        if !role.is_some_and(|x| x == "active" || x == "building") {
            return Ok(false);
        }
        let current = self
            .db
            .query_row("SELECT seq FROM catalog WHERE id=?", [j.file], |r| {
                r.get::<_, u64>(0)
            })?;
        let (lease, status, until) = self.db.query_row(
            "SELECT lease,status,lease_until FROM jobs WHERE instance=? AND file=? AND seq=?",
            params![j.instance, j.file, j.seq],
            |r| {
                Ok((
                    r.get::<_, u64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, u64>(2)?,
                ))
            },
        )?;
        Ok(current == j.seq && lease == j.lease && status == "leased" && until > now())
    }
    pub fn stage(&mut self, j: &Job) -> Result<bool> {
        if self.blocked.contains(&j.instance) {
            bail!("writer must be reopened after unresolved failure")
        }
        if !self.admissible(j)? {
            return Ok(false);
        }
        let applied = self
            .applied
            .get(&j.instance)
            .and_then(|m| m.get(&j.file))
            .copied()
            .unwrap_or(0);
        if j.seq <= applied {
            return Ok(false);
        }
        self.engines
            .get_mut(&j.instance)
            .unwrap()
            .put(j.file, j.seq, j.text.as_deref())?;
        self.applied
            .get_mut(&j.instance)
            .unwrap()
            .insert(j.file, j.seq);
        self.staged
            .entry(j.instance.clone())
            .or_default()
            .push(j.clone());
        Ok(true)
    }
    fn recover(&mut self, instance: &str) -> Result<()> {
        if let Some(payload) = self.engines[instance].payload()?
            && !payload.is_empty()
        {
            let b: Batch = serde_json::from_str(&payload)?;
            self.ack(&b)?;
        }
        self.db.execute(
            "UPDATE jobs SET status='pending' WHERE instance=? AND status='leased'",
            [instance],
        )?;
        Ok(())
    }
    fn ack(&mut self, b: &Batch) -> Result<()> {
        let tx = self.db.transaction()?;
        for j in &b.jobs {
            tx.execute(
                "UPDATE jobs SET status='acked' WHERE instance=? AND file=? AND seq=?",
                params![b.instance, j.file, j.seq],
            )?;
        }
        tx.execute(
            "INSERT OR IGNORE INTO receipts VALUES(?,?)",
            params![b.instance, b.batch],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn commit(&mut self, instance: &str, fault: Fault) -> Result<()> {
        if self.blocked.contains(instance) {
            bail!("writer must be reopened after unresolved failure")
        }
        let old = self.engines[instance]
            .payload()?
            .filter(|p| !p.is_empty())
            .map(|p| serde_json::from_str::<Batch>(&p))
            .transpose()?;
        if let Some(b) = &old {
            let acked = self.db.query_row(
                "SELECT COUNT(*) FROM receipts WHERE instance=? AND batch=?",
                params![instance, b.batch],
                |r| r.get::<_, u64>(0),
            )? > 0;
            if !acked {
                bail!("previous committed batch is not acknowledged")
            }
        }
        let batch = old.map_or(1, |b| b.batch + 1);
        let staged = self.staged.remove(instance).unwrap_or_default();
        // A newer catalog event or lease can arrive after stage. Rebuild the uncommitted batch
        // on this serialized coordinator lane so stale additions/deletions cannot publish.
        self.engines.get_mut(instance).unwrap().rollback()?;
        self.applied
            .insert(instance.into(), self.engines[instance].applied()?);
        let mut jobs = vec![];
        for j in staged {
            let durable = self.applied[instance].get(&j.file).copied().unwrap_or(0);
            if self.admissible(&j)? && j.seq > durable {
                self.engines
                    .get_mut(instance)
                    .unwrap()
                    .put(j.file, j.seq, j.text.as_deref())?;
                self.applied
                    .get_mut(instance)
                    .unwrap()
                    .insert(j.file, j.seq);
                jobs.push(j);
            } else {
                self.db.execute("UPDATE jobs SET status=CASE WHEN seq=(SELECT seq FROM catalog WHERE id=jobs.file) THEN 'pending' ELSE 'superseded' END WHERE instance=? AND file=? AND seq=? AND lease=? AND status='leased'",params![j.instance,j.file,j.seq,j.lease])?;
            }
        }
        let b = Batch {
            instance: instance.into(),
            batch,
            jobs,
        };
        if fault == Fault::BeforeCommit {
            self.engines.get_mut(instance).unwrap().rollback()?;
            self.applied
                .insert(instance.into(), self.engines[instance].applied()?);
            self.db.execute(
                "UPDATE jobs SET status='pending' WHERE instance=? AND status='leased'",
                [instance],
            )?;
            bail!("injected commit failure before durable publication")
        }
        let outcome = if fault == Fault::AmbiguousNotCommitted {
            Err(anyhow::anyhow!(
                "injected uncertain result before publication"
            ))
        } else {
            self.engines
                .get_mut(instance)
                .unwrap()
                .commit(&serde_json::to_string(&b)?)
        };
        if let Err(error) = outcome {
            // rollback waits for the old writer to stop; only then is the durable payload decisive.
            self.blocked.insert(instance.into());
            self.engines.get_mut(instance).unwrap().rollback()?;
            self.applied
                .insert(instance.into(), self.engines[instance].applied()?);
            let observed = self.engines[instance]
                .payload()?
                .filter(|p| !p.is_empty())
                .map(|p| serde_json::from_str::<Batch>(&p))
                .transpose()?;
            if let Some(observed) = observed.filter(|p| p.instance == instance && p.batch == batch)
            {
                self.ack(&observed)?;
                self.blocked.remove(instance);
                return Ok(());
            }
            self.db.execute(
                "UPDATE jobs SET status='pending' WHERE instance=? AND status='leased'",
                [instance],
            )?;
            self.blocked.remove(instance);
            return Err(error);
        }
        if fault == Fault::AfterCommitBeforeAck {
            bail!("injected stop after commit before SQLite ack")
        }
        if fault == Fault::AmbiguousCommitted {
            let observed: Batch =
                serde_json::from_str(&self.engines[instance].payload()?.unwrap())?;
            if observed.batch != batch {
                bail!("ambiguous commit not resolved")
            };
            self.ack(&observed)?;
        } else {
            self.ack(&b)?;
        }
        Ok(())
    }
    pub fn drain(&mut self, instance: &str) -> Result<()> {
        self.recover(instance)?;
        let jobs = self
            .db
            .prepare(
                "SELECT file,seq FROM jobs WHERE instance=? AND status='pending' ORDER BY seq,file",
            )?
            .query_map([instance], |r| {
                Ok((r.get::<_, u64>(0)?, r.get::<_, u64>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for (file, seq) in jobs {
            let j = self.claim(instance, file, seq)?;
            if !self.stage(&j)? {
                self.db.execute(
                    "UPDATE jobs SET status='superseded' WHERE instance=? AND file=? AND seq=?",
                    params![instance, file, seq],
                )?;
            }
        }
        self.commit(instance, Fault::None)
    }
    pub fn begin_rebuild(&mut self, id: &str) -> Result<()> {
        let engine = Engine::open(&self.root.join(id), GramKind::Byte, false)?;
        let tx = self.db.transaction()?;
        let start = tx.query_row("SELECT COALESCE(MAX(jseq),0) FROM operations", [], |r| {
            r.get::<_, u64>(0)
        })?;
        tx.execute(
            "INSERT INTO instances VALUES(?,'building',?)",
            params![id, start],
        )?;
        tx.execute(
            "INSERT INTO jobs(instance,file,seq,text) SELECT ?,id,seq,text FROM catalog",
            [id],
        )?;
        tx.execute(
            "INSERT INTO cursors VALUES(?,?)",
            params![format!("content:{id}"), start],
        )?;
        tx.commit()?;
        self.applied.insert(id.into(), engine.applied()?);
        self.engines.insert(id.into(), engine);
        Ok(())
    }
    pub fn cutover(&mut self, id: &str, fault: Fault) -> Result<()> {
        let role: String =
            self.db
                .query_row("SELECT role FROM instances WHERE id=?", [id], |r| r.get(0))?;
        if role != "building" {
            bail!("cutover target is not building")
        }
        self.drain(id)?;
        if fault == Fault::BeforeCutover {
            bail!("injected stop before instance manifest transaction")
        }
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE instances SET role='retired' WHERE role='active'",
            [],
        )?;
        tx.execute(
            "UPDATE instances SET role='active' WHERE id=? AND role='building'",
            [id],
        )?;
        tx.execute("UPDATE meta SET value=? WHERE key='active'", [id])?;
        tx.commit()?;
        if fault == Fault::AfterCutover {
            bail!("injected stop after instance manifest transaction")
        };
        Ok(())
    }
    pub fn status(&self, j: &Job) -> Result<String> {
        Ok(self.db.query_row(
            "SELECT status FROM jobs WHERE instance=? AND file=? AND seq=?",
            params![j.instance, j.file, j.seq],
            |r| r.get(0),
        )?)
    }
    pub fn publish_names(&mut self) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute("DELETE FROM name_snapshot", [])?;
        tx.execute(
            "INSERT INTO name_snapshot SELECT id,seq FROM catalog WHERE text IS NOT NULL",
            [],
        )?;
        tx.execute("UPDATE cursors SET seq=(SELECT COALESCE(MAX(jseq),0) FROM operations) WHERE consumer='name'",[])?;
        tx.commit()?;
        Ok(())
    }
    pub fn cursor(&self, consumer: &str) -> Result<u64> {
        Ok(self.db.query_row(
            "SELECT seq FROM cursors WHERE consumer=?",
            [consumer],
            |r| r.get(0),
        )?)
    }
    pub fn prune_journal(&mut self) -> Result<usize> {
        let tx = self.db.transaction()?;
        let safe:u64=tx.query_row("SELECT MIN(seq) FROM (SELECT seq FROM cursors WHERE consumer='name' OR consumer IN (SELECT 'content:'||id FROM instances WHERE role IN ('active','building')) UNION ALL SELECT start FROM instances WHERE role='building')",[],|r|r.get(0))?;
        let deleted = tx.execute("DELETE FROM operations WHERE jseq<?", [safe])?;
        tx.commit()?;
        Ok(deleted)
    }
}
