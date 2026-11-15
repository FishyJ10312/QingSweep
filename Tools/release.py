#!/usr/bin/env python3
"""Stage, notarize and verify the tested binary; never modifies the installed local app."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

PROJECT = Path(__file__).resolve().parents[1]


def run(*args, required=True):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if required and p.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name} failed: {p.stdout}{p.stderr}")
    return p


def sha(path):
    with path.open("rb") as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def identities():
    output = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning").stdout
    return dict(re.findall(r'([A-Fa-f0-9]{40}) "(Developer ID Application:[^"\n]+)"', output))


def signature(app, formal=False):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    p = run("/usr/bin/codesign", "-dv", "--verbose=4", app)
    info = p.stdout + p.stderr
    if "runtime" not in info:
        raise RuntimeError("Hardened Runtime is missing")
    if formal and not ("Authority=Developer ID Application:" in info and "Timestamp=" in info
                       and re.search(r"TeamIdentifier=(?!not set)\w+", info)):
        raise RuntimeError("Developer ID, team or secure timestamp is missing")
    ent = run("/usr/bin/codesign", "-d", "--entitlements", ":-", app).stdout
    if "com.apple.security.get-task-allow" in ent:
        raise RuntimeError("Debug entitlement must not be distributed")
    return info


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="Read-only release prerequisite check")
    ap.add_argument("--app", type=Path)
    ap.add_argument("--identity", help="Developer ID Application certificate SHA-1 fingerprint")
    ap.add_argument("--profile", help="Existing notarytool Keychain profile; never pass passwords")
    ap.add_argument("--acceptance", type=Path, help="Acceptance JSON matching this exact executable")
    args = ap.parse_args()
    found = identities()
    status = run("/usr/sbin/spctl", "--status", required=False).stdout.strip()
    report = {"developer_id_identities": found, "gatekeeper": status,
              "notarytool": run("/usr/bin/xcrun", "notarytool", "--version").stdout.strip()}
    if args.check:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0 if found else 2
    if not args.identity or args.identity not in found:
        raise RuntimeError("No matching Developer ID Application identity. Local signing cannot be notarized.")
    if not args.app or not args.profile or not args.acceptance:
        raise RuntimeError("Supply --app, --profile and --acceptance after local acceptance passes.")
    app = args.app.resolve(strict=True)
    acceptance = json.loads(args.acceptance.read_text())
    binary_sha = sha(app / "Contents/MacOS/QingSweep")
    if acceptance.get("binary_sha256") != binary_sha or not acceptance.get("local_acceptance_passed"):
        raise RuntimeError("This binary has not passed the required local acceptance checks.")
    signature(app)
    stage = PROJECT / ".build" / ("distribution-" + uuid.uuid4().hex)
    stage.mkdir(parents=True)
    candidate = stage / "轻扫.app"
    run("/usr/bin/ditto", app, candidate)
    run("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.identity, candidate)
    signature(candidate, formal=True)
    upload = stage / "notarization-upload.zip"
    run("/usr/bin/ditto", "-c", "-k", "--keepParent", candidate, upload)
    p = run("/usr/bin/xcrun", "notarytool", "submit", upload, "--keychain-profile", args.profile, "--wait", "--output-format", "json")
    submission = json.loads(p.stdout)
    (stage / "submission.json").write_text(json.dumps(submission, indent=2))
    if submission.get("id"):
        run("/usr/bin/xcrun", "notarytool", "log", submission["id"], "--keychain-profile", args.profile, stage / "notary-log.json")
    if submission.get("status") != "Accepted":
        raise RuntimeError(f"Notarization was not accepted. Inspect {stage / 'notary-log.json'}")
    log = json.loads((stage / "notary-log.json").read_text())
    run("/usr/bin/xcrun", "stapler", "staple", candidate)
    run("/usr/bin/xcrun", "stapler", "validate", candidate)
    signature(candidate, formal=True)
    # ZIPs cannot be stapled. Repack the stapled app and verify the extracted deliverable.
    package = stage / "轻扫-notarized.zip"
    run("/usr/bin/ditto", "-c", "-k", "--keepParent", candidate, package)
    extract = stage / "extracted"
    run("/usr/bin/ditto", "-x", "-k", package, extract)
    extracted = extract / "轻扫.app"
    signature(extracted, formal=True)
    run("/usr/bin/xcrun", "stapler", "validate", extracted)
    distribution = run("/usr/bin/syspolicy_check", "distribution", extracted, required=False)
    assessment = run("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", extracted, required=False)
    ready = ("assessments enabled" in status and distribution.returncode == 0
             and assessment.returncode == 0 and "override=" not in assessment.stderr
             and not log.get("issues"))
    report.update({"notarized": True, "package": str(package), "sha256": sha(package),
                   "syspolicy": distribution.stdout + distribution.stderr,
                   "assessment": assessment.stdout + assessment.stderr,
                   "notary_issues": log.get("issues"), "distribution_gate_passed": ready,
                   "cross_machine_acceptance_required": True})
    (stage / "release-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if ready else 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
