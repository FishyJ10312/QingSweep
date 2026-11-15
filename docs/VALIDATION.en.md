# 1.8.2 Beta validation

Date: 2026-11-15 · App **1.8.2 (17)** · Tag `v1.8.2-beta`

## Automated checks

**650 checks passed:** the retained 624 regression and crash-recovery checks, plus 26 localization checks. The full-list fixture retains 30,017 files. Localization checks additionally exercise all **787 English catalogue entries**; those catalogue cases are not added to the 650 count.

| Coverage | Checks |
| --- | ---: |
| Core, classification, interaction, storage, index, navigation, manual selection, application boundaries and 1.6–1.8 regressions | 498 |
| Per-file journal, restart reconciliation and crash recovery | 126 |
| Localization, preserved names/paths, preferences, compatibility and English search | 26 |
| **Total** | **650** |

Language coverage includes system-language fallback, singular/plural counts, composed descriptions, filenames that match UI words, paths containing Chinese characters and spaces, retained raw classification identifiers, and English searches against older Chinese-indexed metadata. Language changes update the menu without adding a duplicate memory sample.

## Native English walkthrough

A dedicated native test host used the production interface and cleanup engine with a generated home directory. No personal files were used. Actual UI actions verified:

1. Media and project files start unselected.
2. Changing to English preserves a manual selection and leaves original Chinese filenames unchanged.
3. Select All and individual deselection work, including deselecting the project before review.
4. Review and the second confirmation appear in English; the move button remains disabled until acknowledgment.
5. One generated video moves to Trash, appears in History and is restored from its batch.
6. The restored file matches the original bytes; the generated project and all other fixture files remain byte-identical.
7. English storage search finds older Chinese-indexed application titles. Folder entry and Up return work.
8. Tools display in English. Relaunch retains the language; System default returns to Chinese on the test Mac.

The first walkthrough exposed Chinese item-count suffixes in composed English labels and a sheet locale mismatch. Both were corrected and checked again. Native UI walkthroughs are separate from the 650 automated checks.

The actual user's cleanup history and operation journal remained byte-identical to their pre-test backups. The test host uses a separate data directory.

## Retained crash-recovery coverage

The retained checks include **nine actual SIGKILL windows**: regular cleanup, application-data cleanup and batch restore, each interrupted after intent commit, after moving a file but before result commit, and after per-item result commit. Restart checks verify identity, no duplicate recovery records and no reused deletion confirmation; restoration verifies the original bytes.

The prior 1.8.1 native acceptance also terminated two dedicated test processes and restored the generated files after restart. This is documented separately in [the 1.8.1 record](RELEASE_1.8.1_BETA.md). These are process-termination tests, not physical power-loss tests. Journal write failures use fault injection; the user's real disk was not filled.

## Delivery checks and limits

- Local device: Apple Silicon / macOS 27.2. Deployment target: macOS 14; this does not establish actual macOS 14 device compatibility.
- The app retains its bundle identifier and persistent local signing identity, includes both interface catalogues, the MIT license and attribution, and enables Hardened Runtime.
- Release ZIP contents, signatures and SHA-256 checksums are checked; the curated source excludes personal scan databases, histories and signing secrets.
- The prior 1.8.1 release remains available.
- **No Developer ID signature or Apple notarization.** GitHub open-source publication does not require notarization.
- Still pending: first launch on another Mac with default Gatekeeper, actual macOS 14 hardware, more file systems and physical external-drive unplugging.

The local Mac's security assessment setting was already non-default and was not changed for this work. Local launch therefore does not establish normal Gatekeeper first-launch acceptance. This remains a **Beta / Pre-release**.

Machine-readable record: [validation-1.8.2-beta.json](validation-1.8.2-beta.json).
