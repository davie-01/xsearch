//! Prints extraction statistics (no document text) for each path: `cargo run --example probe -- FILE...`.
use std::{path::Path, time::Instant};
use xs_parsers::{Limits, office};

fn main() {
    for arg in std::env::args().skip(1) {
        let p = Path::new(&arg);
        let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
        let t = Instant::now();
        let r = match ext.as_str() {
            "xlsx" | "xlsm" | "xls" | "ods" => office::spreadsheet(p, Limits::default()),
            "pptx" | "pptm" => office::pptx(p, Limits::default()),
            "ofd" => office::ofd(p, Limits::default()),
            _ => continue,
        };
        match r {
            Ok(e) => println!(
                "{ext}\tchars={}\tanchors={}\tstate={:?}\twarnings={}\t{:?}",
                e.text.chars().count(),
                e.anchors.len(),
                e.state,
                e.warnings.len(),
                t.elapsed()
            ),
            Err(err) => println!("{ext}\terror={err:#}"),
        }
    }
}
