//! Read-only: runs a content query on an index and prints hit statistics (no names or text).
use std::{sync::atomic::AtomicBool, time::Duration};
fn main() {
    let mut a = std::env::args().skip(1);
    let (index, query) = (a.next().unwrap(), a.next().unwrap());
    let exts: Vec<String> = a.collect();
    let r = xs_index::ContentReader::open(std::path::Path::new(&index)).unwrap();
    let mut s = r.session(xs_index::SearchRequest { expr: xs_index::parse(&query).unwrap(), mode: xs_index::Mode::Loose, dirs: vec![], exts, scopes: vec![], size: None, mtime: None }).unwrap();
    let mut hits = vec![];
    loop {
        let b = s.next(Duration::from_secs(10), usize::MAX, &AtomicBool::new(false)).unwrap();
        hits.extend(b.hits);
        if b.done { break; }
    }
    let members = hits.iter().filter(|h| !h.member.is_empty()).count();
    let archives: std::collections::BTreeSet<u64> = hits.iter().filter(|h| !h.member.is_empty()).map(|h| h.file_id).collect();
    let snippets_ok = hits.iter().filter(|h| !h.snippet.is_empty() && !h.snippet_highlights.is_empty()).count();
    println!("hits={} member_hits={} archives={} with_snippet_highlight={}", hits.len(), members, archives.len(), snippets_ok);
}
