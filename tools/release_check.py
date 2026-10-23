#!/usr/bin/env python3
"""Fail closed on missing release configuration/evidence; does not grant approval."""
import json
import ipaddress
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    "signing_and_identifiers_confirmed", "family_controls_distribution_approved",
    "real_device_alarm_matrix", "pose_5_people_30_sets_29_exact",
    "restriction_overlap_recovery", "two_overnight_runs",
    "twenty_languages_accessibility_review", "feedback_production_end_to_end",
    "privacy_support_and_store_metadata", "no_blocking_defects",
)

def public_https_url(value):
    if not isinstance(value, str) or value != value.strip() or any(c.isspace() for c in value):
        return False
    try:
        url = urlparse(value)
        host = (url.hostname or "").lower().rstrip(".")
        _ = url.port  # Reject malformed ports instead of deferring to a browser.
        if url.scheme != "https" or not host or url.username is not None or url.password is not None:
            return False
        if "." not in host or host.endswith((".localhost", ".local", ".invalid", ".test", ".example")):
            return False
        if any(host == domain or host.endswith("." + domain) for domain in ("example.com", "example.org", "example.net")):
            return False
        try:
            if not ipaddress.ip_address(host).is_global:
                return False
        except ValueError:
            pass  # DNS names still require a separate live availability check.
        return True
    except ValueError:
        return False

def check(root=ROOT):
    issues = []
    try:
        config = json.loads((root / "Config/Services.json").read_text())
        evidence = json.loads((root / "Config/ReleaseEvidence.json").read_text())
    except (OSError, ValueError) as error:
        return [f"Configuration unreadable: {error}"]
    if not isinstance(config, dict) or not isinstance(evidence, dict):
        return ["Configuration must contain JSON objects"]
    for key in ("feedbackEndpoint", "privacyURL", "supportURL"):
        if not public_https_url(config.get(key)):
            issues.append(f"Missing production HTTPS URL: {key}")
    app_id = config.get("appStoreID", "")
    if not isinstance(app_id, str) or not app_id or not app_id.isascii() or not app_id.isdigit() or int(app_id) <= 0:
        issues.append("Missing numeric App Store ID")
    for gate in REQUIRED:
        entry = evidence.get(gate, {})
        if not isinstance(entry, dict) or entry.get("passed") is not True or not isinstance(entry.get("evidence"), str) or not entry["evidence"].strip():
            issues.append(f"Unverified release gate: {gate}")
    return issues

if __name__ == "__main__":
    issues = check()
    print("NOT READY" if issues else "CHECKLIST COMPLETE — human review still required")
    for issue in issues:
        print(f"- {issue}")
    sys.exit(1 if issues else 0)
