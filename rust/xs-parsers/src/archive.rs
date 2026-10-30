//! M4 archives: zip / tar / tar.gz / gz / 7z / rar. Members are unpacked to a scratch folder
//! for the caller's own extractors (PDF and .doc live in Swift), one level deep, within limits
//! on member size, total size and member count.
use crate::{Limits, office::open_zip};
use anyhow::{Result, bail};
use std::{
    fs::File,
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub const ARCHIVE_EXTRACTOR_VERSION: u64 = 2;

#[derive(Debug, Clone, Copy)]
pub struct ArchiveLimits {
    pub max_member_bytes: u64,
    pub max_total_bytes: u64,
    pub max_members: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Member {
    /// Path inside the archive.
    pub name: String,
    pub size: u64,
    /// Where it was unpacked (named by index, keeping the extension).
    pub extracted: PathBuf,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Unpacked {
    pub members: Vec<Member>,
    pub skipped_by_type: u32,
    pub skipped_too_large: u32,
    pub encrypted: u32,
    /// Stopped early: total size or member count limit.
    pub truncated: bool,
    pub warnings: Vec<String>,
}

/// Kind by file name; `.tar.gz` before `.gz`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Zip,
    Tar,
    TarGz,
    Gz,
    SevenZ,
    Rar,
}

fn kind(name: &str) -> Option<Kind> {
    let l = name.to_lowercase();
    Some(if l.ends_with(".tar.gz") || l.ends_with(".tgz") {
        Kind::TarGz
    } else if l.ends_with(".gz") {
        Kind::Gz
    } else if l.ends_with(".tar") {
        Kind::Tar
    } else if l.ends_with(".zip") {
        Kind::Zip
    } else if l.ends_with(".7z") {
        Kind::SevenZ
    } else if l.ends_with(".rar") {
        Kind::Rar
    } else {
        return None;
    })
}

/// Later volumes of a multi-part RAR (`x.part2.rar`): everything is read from part 1.
fn later_rar_volume(name: &str) -> bool {
    let l = name.to_lowercase();
    let Some(stem) = l.strip_suffix(".rar") else { return false };
    let Some(pos) = stem.rfind(".part") else { return false };
    stem[pos + 5..].parse::<u32>().is_ok_and(|n| n > 1)
}

struct Sink<'a> {
    dest: &'a Path,
    wanted: &'a dyn Fn(&str) -> bool,
    limits: ArchiveLimits,
    total: u64,
    out: Unpacked,
}

enum Decision {
    Take(PathBuf),
    Skip,
    Stop,
}

impl Sink<'_> {
    /// Whether to unpack this member, and where.
    fn decide(&mut self, name: &str, size: u64) -> Decision {
        if !(self.wanted)(name) {
            self.out.skipped_by_type += 1;
            return Decision::Skip;
        }
        if size > self.limits.max_member_bytes {
            self.out.skipped_too_large += 1;
            return Decision::Skip;
        }
        if self.out.members.len() as u32 >= self.limits.max_members || self.total + size > self.limits.max_total_bytes {
            self.out.truncated = true;
            return Decision::Stop;
        }
        let ext = name.rsplit_once('.').map(|(_, e)| e).unwrap_or("bin");
        Decision::Take(self.dest.join(format!("{}.{}", self.out.members.len(), ext.to_lowercase())))
    }

    /// Copies at most the member limit (headers can lie about sizes).
    fn write(&mut self, name: &str, target: PathBuf, reader: &mut dyn Read) -> Result<()> {
        let mut f = File::create(&target)?;
        let n = std::io::copy(&mut reader.take(self.limits.max_member_bytes + 1), &mut f)?;
        f.flush()?;
        if n > self.limits.max_member_bytes {
            std::fs::remove_file(&target)?;
            self.out.skipped_too_large += 1;
            return Ok(());
        }
        self.total += n;
        self.out.members.push(Member { name: name.to_owned(), size: n, extracted: target });
        Ok(())
    }
}

/// Unpacks the members `wanted` accepts into `dest` (which must exist).
pub fn unpack(path: &Path, dest: &Path, wanted: &dyn Fn(&str) -> bool, limits: ArchiveLimits) -> Result<Unpacked> {
    let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let Some(kind) = kind(file_name) else { bail!("not an archive") };
    let mut sink = Sink { dest, wanted, limits, total: 0, out: Unpacked::default() };
    if later_rar_volume(file_name) {
        sink.out.warnings.push("分卷压缩包的后续分卷，内容在第一卷里".into());
        return Ok(sink.out);
    }
    match kind {
        Kind::Zip => zip(path, &mut sink)?,
        Kind::Tar => tar(File::open(path)?, &mut sink)?,
        Kind::TarGz => tar(flate2::read::MultiGzDecoder::new(File::open(path)?), &mut sink)?,
        Kind::Gz => {
            let name = file_name[..file_name.len() - 3].to_owned();
            if let Decision::Take(target) = sink.decide(&name, 0) {
                sink.write(&name, target, &mut flate2::read::MultiGzDecoder::new(File::open(path)?))?;
            }
        }
        Kind::SevenZ => seven_z(path, &mut sink)?,
        Kind::Rar => rar(path, &mut sink)?,
    }
    if sink.out.encrypted > 0 {
        sink.out.warnings.push(format!("{} 个文件已加密，无法读取", sink.out.encrypted));
    }
    if sink.out.skipped_too_large > 0 {
        sink.out.warnings.push(format!("{} 个文件超过单文件上限，未读取", sink.out.skipped_too_large));
    }
    if sink.out.truncated {
        sink.out.warnings.push("压缩包内容超过上限，后续文件未读取".into());
    }
    Ok(sink.out)
}

/// Member names are raw bytes: UTF-8 when valid (macOS, and zips flagged as UTF-8, even when
/// the flag is missing), otherwise GB18030 (Chinese Windows tools write the local code page).
fn member_name(raw: &[u8]) -> String {
    match std::str::from_utf8(raw) {
        Ok(s) => s.to_owned(),
        Err(_) => encoding_rs::GB18030.decode(raw).0.into_owned(),
    }
}

fn zip(path: &Path, sink: &mut Sink) -> Result<()> {
    let limits = Limits { max_file_bytes: u64::MAX, max_unpacked_bytes: sink.limits.max_total_bytes };
    let mut z = open_zip(path, limits)?;
    for i in 0..z.len() {
        let mut entry = match z.by_index(i) {
            Ok(e) => e,
            Err(zip::result::ZipError::UnsupportedArchive(m)) if m.contains("assword") => {
                sink.out.encrypted += 1;
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        if entry.is_dir() {
            continue;
        }
        if entry.encrypted() {
            sink.out.encrypted += 1;
            continue;
        }
        let name = member_name(entry.name_raw());
        match sink.decide(&name, entry.size()) {
            Decision::Take(target) => sink.write(&name, target, &mut entry)?,
            Decision::Skip => {}
            Decision::Stop => break,
        }
    }
    Ok(())
}

fn tar<R: Read>(reader: R, sink: &mut Sink) -> Result<()> {
    let mut archive = tar::Archive::new(reader);
    for entry in archive.entries()? {
        let mut entry = entry?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let name = member_name(&entry.path_bytes());
        let size = entry.size();
        match sink.decide(&name, size) {
            Decision::Take(target) => sink.write(&name, target, &mut entry)?,
            Decision::Skip => {}
            Decision::Stop => break,
        }
    }
    Ok(())
}

fn seven_z(path: &Path, sink: &mut Sink) -> Result<()> {
    use sevenz_rust2::{ArchiveReader, Error, Password};
    let mut reader = match ArchiveReader::open(path, Password::empty()) {
        Ok(r) => r,
        Err(Error::PasswordRequired | Error::MaybeBadPassword(_)) => {
            sink.out.encrypted += 1;
            return Ok(());
        }
        Err(e) => return Err(e.into()),
    };
    let mut failure: Option<anyhow::Error> = None;
    let result = reader.for_each_entries(|entry, data| {
        if entry.is_directory() || !entry.has_stream() {
            return Ok(true);
        }
        let name = entry.name().to_owned();
        match sink.decide(&name, entry.size()) {
            Decision::Take(target) => {
                if let Err(e) = sink.write(&name, target, data) {
                    failure = Some(e);
                    return Ok(false);
                }
            }
            // Solid archives decode sequentially: skipping still has to read through.
            Decision::Skip => {
                std::io::copy(data, &mut std::io::sink())?;
            }
            Decision::Stop => return Ok(false),
        }
        Ok(true)
    });
    if let Some(e) = failure {
        return Err(e);
    }
    match result {
        Ok(()) => Ok(()),
        Err(Error::PasswordRequired | Error::MaybeBadPassword(_)) => {
            sink.out.encrypted += 1;
            Ok(())
        }
        Err(e) => Err(e.into()),
    }
}

fn rar(path: &Path, sink: &mut Sink) -> Result<()> {
    let mut archive = match unrar::Archive::new(path).open_for_processing() {
        Ok(a) => a,
        // Encrypted file names: nothing can be listed without the password.
        Err(e) if format!("{e:?}").contains("MissingPassword") || format!("{e:?}").contains("BadPassword") => {
            sink.out.encrypted += 1;
            return Ok(());
        }
        Err(e) => bail!("rar: {e}"),
    };
    while let Some(header) = archive.read_header()? {
        let entry = header.entry();
        let name = entry.filename.to_string_lossy().into_owned();
        let size = entry.unpacked_size;
        archive = if !entry.is_file() {
            header.skip()?
        } else if entry.is_encrypted() {
            sink.out.encrypted += 1;
            header.skip()?
        } else {
            match sink.decide(&name, size) {
                Decision::Take(target) => {
                    let next = header.extract_to(&target)?;
                    let n = std::fs::metadata(&target).map(|m| m.len()).unwrap_or(0);
                    sink.total += n;
                    sink.out.members.push(Member { name, size: n, extracted: target });
                    next
                }
                Decision::Skip => header.skip()?,
                Decision::Stop => break,
            }
        };
    }
    Ok(())
}
