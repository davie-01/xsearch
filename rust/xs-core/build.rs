use std::{env, fs, path::PathBuf};
fn main() {
    let source = "../../Tests/Fixtures/m0/CaseFolding-17.0.0.txt";
    println!("cargo:rerun-if-changed={source}");
    let data = fs::read_to_string(source).expect("Missing pinned Unicode CaseFolding fixture");
    let mut rows = std::collections::BTreeMap::new();
    for line in data.lines() {
        let line = line.split('#').next().unwrap().trim();
        if line.is_empty() {
            continue;
        }
        let f: Vec<_> = line.split(';').map(str::trim).collect();
        if f[1] != "C" && f[1] != "F" {
            continue;
        }
        let key = u32::from_str_radix(f[0], 16).unwrap();
        let value = f[2]
            .split_whitespace()
            .map(|x| format!("\\u{{{x}}}"))
            .collect::<String>();
        rows.insert(key, value);
    }
    let mut out = "pub fn fold(c: char) -> Option<&'static str> { match c as u32 {\n".to_string();
    for (key, value) in rows {
        out += &format!("{key} => Some(\"{value}\"),\n");
    }
    out += "_ => None } }\n";
    fs::write(
        PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("casefold.rs"),
        out,
    )
    .unwrap();
}
