use std::io::Write;
use std::path::Path;
use xs_parsers::archive::{ArchiveLimits, unpack};

const LIMITS: ArchiveLimits = ArchiveLimits { max_member_bytes: 1 << 20, max_total_bytes: 8 << 20, max_members: 100 };

fn docs(name: &str) -> bool {
    name.ends_with(".txt") || name.ends_with(".docx")
}

fn names(u: &xs_parsers::archive::Unpacked) -> Vec<&str> {
    u.members.iter().map(|m| m.name.as_str()).collect()
}

#[test]
fn zip_members_by_type_and_limits() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.zip");
    let mut z = zip::ZipWriter::new(std::fs::File::create(&p).unwrap());
    for (name, body) in [("合同/一.txt", "甲方".to_string()), ("图.png", "x".into()), ("大.txt", "y".repeat(2 << 20)), ("dir/", String::new())] {
        if name.ends_with('/') {
            z.add_directory(name, zip::write::SimpleFileOptions::default()).unwrap();
        } else {
            z.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(body.as_bytes()).unwrap();
        }
    }
    z.finish().unwrap();
    let out = tempfile::tempdir().unwrap();
    let u = unpack(&p, out.path(), &docs, LIMITS).unwrap();
    assert_eq!(names(&u), vec!["合同/一.txt"]);
    assert_eq!((u.skipped_by_type, u.skipped_too_large), (1, 1));
    assert_eq!(std::fs::read_to_string(&u.members[0].extracted).unwrap(), "甲方");
    // Unpacked under an index name: archive paths never reach the file system.
    assert_eq!(u.members[0].extracted.parent(), Some(out.path()));
}

#[test]
fn tar_gz_gz_and_member_count_limit() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("b.tar.gz");
    let gz = flate2::write::GzEncoder::new(std::fs::File::create(&p).unwrap(), flate2::Compression::default());
    let mut t = tar::Builder::new(gz);
    for i in 0..3 {
        let body = format!("第 {i} 份");
        let mut h = tar::Header::new_gnu();
        h.set_size(body.len() as u64);
        h.set_mode(0o644);
        h.set_cksum();
        t.append_data(&mut h, format!("d/{i}.txt"), body.as_bytes()).unwrap();
    }
    t.into_inner().unwrap().finish().unwrap();
    let out = tempfile::tempdir().unwrap();
    let u = unpack(&p, out.path(), &docs, ArchiveLimits { max_members: 2, ..LIMITS }).unwrap();
    assert_eq!((names(&u), u.truncated), (vec!["d/0.txt", "d/1.txt"], true));

    let g = dir.path().join("notes.txt.gz");
    let mut e = flate2::write::GzEncoder::new(std::fs::File::create(&g).unwrap(), flate2::Compression::default());
    e.write_all("单个压缩文件".as_bytes()).unwrap();
    e.finish().unwrap();
    let u = unpack(&g, out.path(), &docs, LIMITS).unwrap();
    assert_eq!(names(&u), vec!["notes.txt"]);
}

#[test]
fn seven_z_members() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("c.7z");
    let mut w = sevenz_rust2::ArchiveWriter::create(&p).unwrap();
    for (name, body) in [("说明.txt", "七号压缩"), ("skip.bin", "z")] {
        w.push_archive_entry(sevenz_rust2::ArchiveEntry::new_file(name), Some(body.as_bytes())).unwrap();
    }
    w.finish().unwrap();
    let out = tempfile::tempdir().unwrap();
    let u = unpack(&p, out.path(), &docs, LIMITS).unwrap();
    assert_eq!((names(&u), u.skipped_by_type), (vec!["说明.txt"], 1));
    assert_eq!(std::fs::read_to_string(&u.members[0].extracted).unwrap(), "七号压缩");
}

#[test]
fn rar_plain_encrypted_and_later_volume() {
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Tests/Fixtures/m4/rar");
    let out = tempfile::tempdir().unwrap();
    let u = unpack(&fixtures.join("version.rar"), out.path(), &|_| true, LIMITS).unwrap();
    assert_eq!(names(&u), vec!["VERSION"]);
    assert!(std::fs::metadata(&u.members[0].extracted).unwrap().len() > 0);
    let c = unpack(&fixtures.join("crypted.rar"), out.path(), &|_| true, LIMITS).unwrap();
    assert!(c.members.is_empty() && c.encrypted >= 1 && !c.warnings.is_empty());
    let later = out.path().join("x.part2.rar");
    std::fs::write(&later, b"Rar!").unwrap();
    assert!(unpack(&later, out.path(), &|_| true, LIMITS).unwrap().members.is_empty());
}

#[test]
fn zip_names_without_utf8_flag() {
    // A zip from a Chinese Windows tool: GBK name bytes, no UTF-8 flag.
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("gbk.zip");
    let mut z = zip::ZipWriter::new(std::fs::File::create(&p).unwrap());
    z.start_file("PLACEHOLDER.txt", zip::write::SimpleFileOptions::default()).unwrap();
    z.write_all(b"x").unwrap();
    z.finish().unwrap();
    let (gbk, _, _) = encoding_rs::GBK.encode("合同.txt");
    assert_eq!(gbk.len(), "PLACEHOLDER.txt".len() - 7);
    let mut data = std::fs::read(&p).unwrap();
    // Patch both the local and central headers: name length and bytes, UTF-8 flag cleared.
    for sig in [&b"PK\x03\x04"[..], &b"PK\x01\x02"[..]] {
        let at = data.windows(4).position(|w| w == sig).unwrap();
        let (flag_at, len_at, name_at) = if sig[2] == 3 { (at + 6, at + 26, at + 30) } else { (at + 8, at + 28, at + 46) };
        data[flag_at] &= !0x00;
        data[flag_at + 1] &= !0x08;
        let old = u16::from_le_bytes([data[len_at], data[len_at + 1]]) as usize;
        data[len_at..len_at + 2].copy_from_slice(&(gbk.len() as u16).to_le_bytes());
        data.splice(name_at..name_at + old, gbk.iter().copied());
    }
    // Central directory offset and size moved by the shorter local name.
    let shrink = "PLACEHOLDER.txt".len() - gbk.len();
    let eocd = data.windows(4).rposition(|w| w == b"PK\x05\x06").unwrap();
    let off = u32::from_le_bytes(data[eocd + 16..eocd + 20].try_into().unwrap()) - shrink as u32;
    let size = u32::from_le_bytes(data[eocd + 12..eocd + 16].try_into().unwrap()) - shrink as u32;
    data[eocd + 16..eocd + 20].copy_from_slice(&off.to_le_bytes());
    data[eocd + 12..eocd + 16].copy_from_slice(&size.to_le_bytes());
    std::fs::write(&p, &data).unwrap();
    let out = tempfile::tempdir().unwrap();
    let u = unpack(&p, out.path(), &docs, LIMITS).unwrap();
    assert_eq!(names(&u), vec!["合同.txt"]);
}

#[test]
fn gz_without_a_size_stops_at_the_total_budget() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("big.txt.gz");
    let mut gz = flate2::write::GzEncoder::new(std::fs::File::create(&p).unwrap(), flate2::Compression::default());
    gz.write_all(&vec![b'x'; 100_000]).unwrap();
    gz.finish().unwrap();
    let out = dir.path().join("out");
    std::fs::create_dir(&out).unwrap();
    let u = unpack(&p, &out, &|_| true, ArchiveLimits { max_member_bytes: 1 << 20, max_total_bytes: 1000, max_members: 10 }).unwrap();
    assert!(u.members.is_empty() && u.truncated, "{:?}", u.members);
    assert_eq!(std::fs::read_dir(&out).unwrap().count(), 0, "nothing beyond the budget stays on disk");
}
