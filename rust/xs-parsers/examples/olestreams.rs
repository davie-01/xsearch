//! Stream names of OLE2 / zip entries of interest (structure only): `olestreams FILE...`.
fn main() {
    for a in std::env::args().skip(1) {
        let ext = a.rsplit('.').next().unwrap_or("").to_lowercase();
        if let Ok(c) = cfb::open(&a) {
            let mut names: Vec<String> = c.walk().filter(|e| e.is_stream()).map(|e| e.path().to_string_lossy().into_owned()).collect();
            names.sort();
            println!("{ext}\tole\t{}", names.join(","));
        } else if let Ok(z) = zip::ZipArchive::new(std::fs::File::open(&a).unwrap()) {
            let mut names: Vec<&str> = z.file_names().filter(|n| n.ends_with(".xml") && !n.contains("/_rels/")).filter(|n| n.matches('/').count() <= 1).collect();
            names.sort();
            println!("{ext}\tzip\t{}", names.join(","));
        } else {
            println!("{ext}\tunknown");
        }
    }
}
