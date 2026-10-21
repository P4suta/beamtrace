#![cfg(feature = "client")]

use serde_json::Value;
use std::path::Path;
use std::process::{Command, Stdio};

const HARNESS: &str = "reject_unauthenticated_publication";
const KANI_VERSION: &str = "0.68.0";

#[test]
#[ignore = "requires the pinned Kani distribution; CI runs this after setup"]
fn the_proof_gate_rejects_the_false_claim_with_an_assertion_counterexample()
-> Result<(), Box<dyn std::error::Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let directory = tempfile::tempdir()?;
    let receipt = directory.path().join("rejection.json");
    let output = Command::new("cargo")
        .current_dir(root)
        .args([
            "kani",
            "--no-default-features",
            "--lib",
            "--features",
            "rejection-probe",
            "--harness",
            HARNESS,
            "--exact",
            "--output-format",
            "terse",
            "-Z",
            "unstable-options",
            "--export-json",
        ])
        .arg(&receipt)
        .stdin(Stdio::null())
        .output()?;
    assert_eq!(
        output.status.code(),
        Some(1),
        "counterexample must fail verification"
    );
    let report: Value = serde_json::from_slice(&std::fs::read(receipt)?)?;
    assert_eq!(report["metadata"]["kani_version"], KANI_VERSION);
    let summary = &report["verification_results"]["summary"];
    assert_eq!(summary["status"], "completed");
    assert_eq!(summary["executed"], 1);
    assert_eq!(summary["failed"], 1);
    let results = report["verification_results"]["results"]
        .as_array()
        .ok_or("missing proof results")?;
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["harness_id"], HARNESS);
    assert_eq!(results[0]["status"], "Failure");
    let checks = results[0]["checks"]
        .as_array()
        .ok_or("missing proof properties")?;
    assert!(
        checks
            .iter()
            .any(|check| check["status"] == "Failure" && check["category"] == "assertion")
    );
    assert!(checks.iter().all(|check| matches!(
        check["status"].as_str(),
        Some("Success" | "Unreachable")
    ) || check["status"] == "Failure"
        && check["category"] == "assertion"));
    assert_eq!(
        report["error_details"][0]["error_type"],
        "assertion_failure"
    );
    Ok(())
}
