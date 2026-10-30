//! Archive statistics (no names or text): `archprobe SCRATCH_DIR ARCHIVE...`.
use std::{path::Path, time::Instant};
use xs_parsers::archive::{ArchiveLimits, unpack};

const DOCS: [&str; 22] = ["txt", "md", "csv", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "ofd", "html", "htm", "epub", "rtf", "wps", "json", "xml", "log", "et", "ods", "odt"];

fn main() {
    let mut args = std::env::args().skip(1);
    let scratch = args.next().unwrap();
    let limits = ArchiveLimits { max_member_bytes: 100 << 20, max_total_bytes: 256 << 20, max_members: 5000 };
    for a in args {
        let dir = Path::new(&scratch).join("x");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let ext = a.rsplit('.').next().unwrap_or("").to_lowercase();
        let t = Instant::now();
        let wanted = |n: &str| n.rsplit_once('.').is_some_and(|(_, e)| DOCS.contains(&e.to_lowercase().as_str()));
        match unpack(Path::new(&a), &dir, &wanted, limits) {
            Ok(u) => println!(
                "{ext}\tok\tmembers={}\tbytype={}\tlarge={}\tencrypted={}\ttruncated={}\tms={}",
                u.members.len(), u.skipped_by_type, u.skipped_too_large, u.encrypted, u.truncated, t.elapsed().as_millis()
            ),
            Err(e) => println!("{ext}\terror\t{}", format!("{e:#}").chars().filter(|c| !c.is_ascii_digit()).take(80).collect::<String>()),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
