use anyhow::{Context, Result, bail};
use std::path::Path;
use xs_core::{
    index::{Engine, GramKind},
    normalize::{Mode, normalize},
    query::parse,
    recovery::{Coordinator, Fault},
    validation::{self, Document},
};
fn main() -> Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let arg = |i: usize| {
        args.get(i)
            .map(String::as_str)
            .context("missing argument; use xs help")
    };
    match args.first().map(String::as_str).unwrap_or("help") {
        "unicode-vectors" => {
            let mut out = vec![];
            for c in (0..=0x10ffff).filter_map(char::from_u32) {
                let s = c.to_string();
                if normalize(&s, Mode::Loose).text != s
                    || normalize(&s, Mode::CaseSensitive).text != s
                    || c.is_whitespace()
                {
                    for mode in Mode::ALL {
                        out.push(serde_json::json!({"input":format!("x{c}y"),"mode":mode}));
                    }
                }
            }
            println!("{}", serde_json::to_string(&out)?);
        }
        "help" => println!(
            "XSearch M0 validation CLI\n  xs validate OUTPUT_DIR [CORPUS.json]\n  xs benchmark OUTPUT_DIR CORPUS.json\n  xs index INDEX_DIR CORPUS.json\n  xs search INDEX_DIR QUERY [loose|case_sensitive|strict]\n  xs normalize VECTORS.json\n  xs extract PATH [ENCODING]\n  xs fault ROOT before-commit|after-commit|before-cutover|after-cutover\n  xs recover ROOT"
        ),
        "validate" => {
            let docs: Vec<Document> = if let Some(p) = args.get(2) {
                serde_json::from_slice(&std::fs::read(p)?)?
            } else {
                vec![]
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&validation::verify(Path::new(arg(1)?), &docs)?)?
            );
        }
        "benchmark" => {
            let docs: Vec<Document> = serde_json::from_slice(&std::fs::read(arg(2)?)?)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&validation::benchmark(Path::new(arg(1)?), &docs)?)?
            );
        }
        "normalize" => {
            let v: Vec<serde_json::Value> = serde_json::from_slice(&std::fs::read(arg(1)?)?)?;
            let out = v
                .iter()
                .map(|x| {
                    Ok(normalize(
                        x["input"].as_str().context("input")?,
                        serde_json::from_value(x["mode"].clone())?,
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            println!("{}", serde_json::to_string(&out)?);
        }
        "extract" => {
            let p = Path::new(arg(1)?);
            let e = if p.extension().is_some_and(|x| x == "docx") {
                xs_core::extract::docx(p)?
            } else {
                xs_core::extract::text(&std::fs::read(p)?, args.get(2).map(String::as_str))?
            };
            println!("{}", serde_json::to_string(&e)?);
        }
        "index" => {
            let docs: Vec<Document> = serde_json::from_slice(&std::fs::read(arg(2)?)?)?;
            let mut e = Engine::open(Path::new(arg(1)?), GramKind::Byte, false)?;
            for d in &docs {
                e.put(d.id, 1, Some(&d.text))?;
            }
            e.commit("CLI import")?;
            println!("{}", serde_json::json!({"indexed":docs.len()}));
        }
        "search" => {
            let mode = match args.get(3).map(String::as_str).unwrap_or("loose") {
                "loose" => Mode::Loose,
                "case_sensitive" => Mode::CaseSensitive,
                "strict" => Mode::Strict,
                _ => bail!("unknown mode"),
            };
            let e = Engine::open(Path::new(arg(1)?), GramKind::Byte, false)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&e.search(&parse(arg(2)?)?, mode, false)?)?
            );
        }
        "fault" => {
            let mut c = Coordinator::open(Path::new(arg(1)?))?;
            c.event(1, Some("original 合同"), "create")?;
            c.drain("initial")?;
            c.publish_names()?;
            let kind = arg(2)?;
            if kind == "journal-uncommitted" {
                // Deliberately terminate with a live SQLite transaction after journal/catalog writes.
                c.db.execute_batch("BEGIN IMMEDIATE;UPDATE catalog SET seq=2,text='uncommitted' WHERE id=1;INSERT INTO operations(file,seq,kind) VALUES(1,2,'modify');")?;
            } else if kind.contains("cutover") {
                c.begin_rebuild("replacement")?;
                c.event(1, Some("latest 合同"), "modify")?;
                if kind == "cutover-uncommitted" {
                    c.drain("replacement")?;
                    c.db.execute_batch("BEGIN IMMEDIATE;UPDATE instances SET role='retired' WHERE role='active';UPDATE meta SET value='replacement' WHERE key='active';")?;
                } else {
                    let error = c
                        .cutover(
                            "replacement",
                            if kind == "before-cutover" {
                                Fault::BeforeCutover
                            } else {
                                Fault::AfterCutover
                            },
                        )
                        .expect_err("fault not triggered");
                    anyhow::ensure!(error.to_string().contains("injected stop"), "{error}");
                }
            } else {
                let seq = c.event(1, Some("latest 合同"), "modify")?;
                if kind == "after-event" {
                    std::process::exit(86)
                }
                if kind == "after-name" {
                    c.publish_names()?;
                    std::process::exit(86)
                }
                let j = c.claim("initial", 1, seq)?;
                if kind == "after-lease" {
                    std::process::exit(86)
                }
                c.stage(&j)?;
                if kind == "after-stage" {
                    std::process::exit(86)
                }
                if kind == "after-ack" {
                    c.commit("initial", Fault::None)?;
                    std::process::exit(86)
                }
                let error = c
                    .commit(
                        "initial",
                        if kind == "before-commit" {
                            Fault::BeforeCommit
                        } else if kind == "after-commit" {
                            Fault::AfterCommitBeforeAck
                        } else {
                            bail!("unknown fault")
                        },
                    )
                    .expect_err("fault not triggered");
                anyhow::ensure!(error.to_string().contains("injected"), "{error}");
            }
            // Exit without Rust destructors to exercise persistent recovery, not graceful drop.
            std::process::exit(86);
        }
        "recover" => {
            let mut c = Coordinator::open(Path::new(arg(1)?))?;
            let active = c.active()?;
            c.drain(&active)?;
            let expected = args.get(2).map(String::as_str).unwrap_or("latest");
            let r = c.engines[&active].search(&parse(expected)?, Mode::Strict, false)?;
            anyhow::ensure!(r.ids == vec![1], "recovery lost expected durable operation");
            c.publish_names()?;
            println!(
                "{}",
                serde_json::json!({"active":active,"ids":r.ids,"source_cursor":c.cursor("source")?,"name_cursor":c.cursor("name")?})
            );
        }
        _ => bail!("unknown command; use xs help"),
    }
    Ok(())
}
