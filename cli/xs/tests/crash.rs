use std::process::Command;
#[test]
fn abrupt_exit_recovers_real_disk_state() {
    let root = std::env::temp_dir().join(format!("xsearch-m0-crash-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    for point in [
        "journal-uncommitted",
        "after-event",
        "after-name",
        "after-lease",
        "after-stage",
        "before-commit",
        "after-commit",
        "after-ack",
        "before-cutover",
        "cutover-uncommitted",
        "after-cutover",
    ] {
        let p = root.join(point);
        let status = Command::new(env!("CARGO_BIN_EXE_xs"))
            .args(["fault", p.to_str().unwrap(), point])
            .output()
            .unwrap();
        assert_eq!(
            status.status.code(),
            Some(86),
            "{}",
            String::from_utf8_lossy(&status.stderr)
        );
        let recovered = Command::new(env!("CARGO_BIN_EXE_xs"))
            .args([
                "recover",
                p.to_str().unwrap(),
                if point == "journal-uncommitted" {
                    "original"
                } else {
                    "latest"
                },
            ])
            .output()
            .unwrap();
        assert!(
            recovered.status.success(),
            "{point}: {}",
            String::from_utf8_lossy(&recovered.stderr)
        );
        let report: serde_json::Value = serde_json::from_slice(&recovered.stdout).unwrap();
        assert_eq!(
            report["active"],
            if point == "after-cutover" {
                "replacement"
            } else {
                "initial"
            }
        );
        let expected_cursor = if point == "journal-uncommitted" { 1 } else { 2 };
        assert_eq!(report["source_cursor"], expected_cursor);
        assert_eq!(report["name_cursor"], expected_cursor);
    }
    std::fs::remove_dir_all(root).unwrap();
}
