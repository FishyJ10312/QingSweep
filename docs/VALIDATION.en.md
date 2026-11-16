# 1.8.3 Beta validation

2026-11-16 · App **1.8.3 (18)** · `v1.8.3-beta`

## Automated checks

`zsh check.sh` completed with exit 0. **751 grouped checks passed**, with no failed or unavailable/skip checks. This retains the previous 650, adds 100 targeted regressions and one additional retained 1.8 check. The standalone **30,017-file complete-list fixture** is reported separately, following the previous release’s counting convention. All 64 frozen source/test/resource inputs stayed unchanged during the run.

| Area | New checks |
| --- | ---: |
| Retained-copy retry: current source/copy equality, identity, cancellation, changed and older records | 21 |
| Login-item state: real disabled/loaded inputs, uncertain queries, cancellation and before/after-effect errors, recovery failure | 61 |
| All-locations scope: narrow-to-expanded index, retained chosen roots, duplicate roots, byte accounting, repeat/cancel/fresh scans | 18 |

The existing 1.8 regression also gains an explicit changed-source rejection while preserving ordinary retry reclassification. Existing startup mocks now assert complete query/change/recovery sequences instead of only the last command. No original test was removed to obtain a pass.

All **800 English catalogue entries** render the reviewed strings; these catalogue cases are separate from the 751 grouped checks. The 26 localization checks remain included in that total.

## Native walkthrough and file checks

The production views and cleanup engine ran inside a dedicated native host with generated files only. Actual UI actions verified:

1. Adding recommendations leaves media and projects unselected.
2. Manual Select All works; deselecting the project group retains the video choice. Entering a cleanup group and returning preserves that choice.
3. Switching to English preserves selections. The second-confirmation move button is disabled until acknowledgment.
4. One generated video actually moves to Trash and is restored by batch, using English UI.
5. In Chinese UI, removing the installer group on the final review leaves only the generated cache. The cache actually moves to Trash and is restored by batch.
6. All six original fixture files match their pre-test SHA-256 values, including the unselected project, notes and deselected installer. Both operation-journal entries end in `restored`.
7. Storage folder entry, Up return and the separate all-locations/current-scope rescan entries are present and operable. Full scope expansion is verified by the 18 actual-index checks above.
8. The system-language preference is restored. The final production 1.8.3 app is installed at the existing path and launched successfully; its executable matches the packaged binary.

The user’s history stayed byte-identical. The real journal payload stayed unchanged: production startup increased only two SQLite header counters by one. Reversing those two counter values in memory exactly reproduced the pre-test file hash; no original database was rewritten for this comparison. Native fixture operations used a separate data directory.

## Crash and startup coverage

The 126 retained recovery checks include nine newly executed real SIGKILL windows: cleanup, managed application data and restore, each interrupted after intent commit, after filesystem move and after result commit. All generated files were restored byte-identically. These are process-termination tests, not physical power-loss tests.

A generated real LaunchAgent passed disable and enable checks. Startup error/cancellation/rollback fault cases use command-boundary fixtures; they do not intentionally fail or alter a personal login item. No personal application was asked to quit by the test suite.

## Delivery and limits

- Apple Silicon / macOS 27.2; deployment target macOS 14. Actual macOS 14 hardware has not been exercised.
- The installed app retains its bundle identifier and persistent local signing identity, passes strict signature validation and enables Hardened Runtime.
- English and Simplified Chinese, MIT license and attribution are included. Curated source excludes personal scan databases, histories and signing credentials.
- App/source ZIP contents and SHA-256 checksums are verified. The 1.8.2 backup, tag and release assets are retained.
- **No Developer ID signature or Apple notarization.** Another Mac with default Gatekeeper and physical external-drive disconnection remain unverified. The local machine’s pre-existing security assessment setting was not changed. This remains a **Beta / Pre-release**.

Machine-readable record: [validation-1.8.3-beta.json](validation-1.8.3-beta.json).
