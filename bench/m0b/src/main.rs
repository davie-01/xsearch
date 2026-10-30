mod names;
mod storage;
use anyhow::{Context, Result, bail};
use std::path::Path;
fn main() -> Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    match args.first().map(String::as_str) {
        Some("names") => {
            let sizes = args
                .iter()
                .skip(1)
                .map(|s| s.parse())
                .collect::<std::result::Result<Vec<usize>, _>>()?;
            let sizes = if sizes.is_empty() {
                vec![100_000, 1_000_000]
            } else {
                sizes
            };
            println!("{}", serde_json::to_string_pretty(&names::run(&sizes)?)?);
        }
        Some("storage") => {
            let root = Path::new(args.get(1).context("output directory required")?);
            anyhow::ensure!(!root.exists(), "use a fresh output directory");
            std::fs::create_dir_all(root)?;
            let docs = serde_json::from_slice::<Vec<xs_core::validation::Document>>(
                &std::fs::read(args.get(2).context("corpus JSON required")?)?,
            )?;
            let read = storage::stored_reads(&root.join("read"), &docs)?;
            let bloom = storage::bloom_reads(&root.join("bloom"), &docs)?;
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &serde_json::json!({"stored_reads":read,"bloom_reads":bloom})
                )?
            );
        }
        _ => bail!("xs-m0b names [COUNTS...] | storage NEW_DIR CORPUS.json"),
    }
    Ok(())
}
