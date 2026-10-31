"""Collects regression metrics from scripts/regression.sh output and compares them with the
baseline (or records it with --update-baseline). Exit status 1 on a regression."""
import json, re, sys
from pathlib import Path

out, baseline_path = Path(sys.argv[1]), Path(sys.argv[2])
update = "--update-baseline" in sys.argv[3:]
metrics = {}  # name -> (value, kind): kind is "ms", "mb" or "count"

# Name engine: "build N ms, memory M MB, overlay K" and per-query "q hits H p50 X ms p95 Y ms".
for line in (out / "name-bench.log").read_text(encoding="utf-8").splitlines():
    if m := re.search(r"build (\d+) ms, memory (\d+) MB", line):
        metrics["name.build"] = (float(m[1]), "ms")
        metrics["name.memory"] = (float(m[2]), "mb")
    elif m := re.match(r"\s*(.+?)\s+hits\s+(\d+)\s+p50\s+([\d.]+) ms\s+p95\s+([\d.]+) ms", line):
        metrics[f"name.{m[1].strip()}.p95"] = (float(m[4]), "ms")
        metrics[f"name.{m[1].strip()}.hits"] = (float(m[2]), "count")
if "name.build" not in metrics:
    sys.exit("name benchmark produced no numbers (see name-bench.log)")

# Content queries.
report = json.loads((out / "content-bench.json").read_text(encoding="utf-8"))[0]
metrics["content.build"] = (float(report["build_ms"]), "ms")
for q in report["queries"]:
    metrics[f"content.{q['query']}.first_p95"] = (q["first_p95_ms"], "ms")
    metrics[f"content.{q['query']}.full_p95"] = (q["full_p95_ms"], "ms")
    metrics[f"content.{q['query']}.hits"] = (float(q["hits"]), "count")

# Extraction (one line per file, in argument order).
for name, line in zip(["docx", "txt", "large-txt"], (out / "extract.tsv").read_text(encoding="utf-8").splitlines()):
    cols = dict(c.split("=", 1) for c in line.split("\t") if "=" in c)
    if "ms" not in cols:
        sys.exit(f"extraction failed: {line}")
    metrics[f"extract.{name}"] = (float(cols["ms"]), "ms")
    metrics[f"extract.{name}.chars"] = (float(cols["chars"]), "count")

if update:
    baseline_path.write_text(json.dumps({k: {"value": v, "kind": kind} for k, (v, kind) in sorted(metrics.items())},
                                        ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"baseline written: {len(metrics)} metrics → {baseline_path}")
    sys.exit(0)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
failures, rows = [], []
for key, entry in sorted(baseline.items()):
    if key not in metrics:
        failures.append(f"{key}: missing")
        continue
    base, (value, kind) = entry["value"], metrics[key]
    if kind == "count":
        bad = value != base
    elif kind == "mb":
        bad = value > base * 1.2
    else:
        bad = value > base * 1.5 and value - base > 5
    rows.append(f"{'✘' if bad else ' '} {key:<48} {base:>10.1f} → {value:>10.1f} {kind}")
    if bad:
        failures.append(f"{key}: {base:.1f} → {value:.1f} {kind}")
print("\n".join(rows))
new = sorted(set(metrics) - set(baseline))
if new:
    print(f"(not in baseline: {', '.join(new)})")
if failures:
    print("\nREGRESSIONS:\n  " + "\n  ".join(failures))
    sys.exit(1)
print(f"\nOK: {len(rows)} metrics within limits")
