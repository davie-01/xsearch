//! Read-only: total extracted text vs. index size (no names or text printed).
use tantivy::{Index, TantivyDocument, Term, collector::DocSetCollector, query::TermQuery, schema::{IndexRecordOption, Value}};
fn main() {
    let dir = std::env::args().nth(1).unwrap();
    let index = Index::open_in_dir(&dir).unwrap();
    let text = index.schema().get_field("display_text").unwrap();
    let live = index.schema().get_field("live").unwrap();
    let searcher = index.reader().unwrap().searcher();
    let (mut docs, mut bytes, mut chars) = (0u64, 0u64, 0u64);
    let q = TermQuery::new(Term::from_field_u64(live, 1), IndexRecordOption::Basic);
    for addr in searcher.search(&q, &DocSetCollector).unwrap() {
        let d: TantivyDocument = searcher.doc(addr).unwrap();
        let t = d.get_first(text).and_then(|v| v.as_str()).unwrap_or("");
        docs += 1;
        bytes += t.len() as u64;
        chars += t.chars().count() as u64;
    }
    let size: u64 = walk(std::path::Path::new(&dir));
    println!("docs={docs} text_utf8_bytes={bytes} chars={chars} index_bytes={size} ratio={:.2}", size as f64 / bytes.max(1) as f64);
}
fn walk(p: &std::path::Path) -> u64 {
    std::fs::read_dir(p).unwrap().flatten().map(|e| { let m = e.metadata().unwrap(); if m.is_dir() { walk(&e.path()) } else { m.len() } }).sum()
}
