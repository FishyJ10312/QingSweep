# 1.8.4 Beta validation

2026-11-16 · **1.8.4 (19)** · `v1.8.4-beta`

## Scope and findings

This audit began with anonymous downloads of the public **1.8.3 Beta** app and source. Archive hashes, the sealed app signature, executable identity and source correspondence were checked before changes.

| Finding | Fix |
| --- | --- |
| A denied common-location scan left only an error-details page without a recovery action | Persist structured unread locations, open the access assistant, retain an unread banner, and provide folder selection, System Settings and real rechecks |
| Relaunch after access recovery retained old scan results | Probe previously denied locations and rescan the saved valid scope only when reads recover; preserve manual deselection |
| Media named “footage” or preset keywords appeared as preset packs | Recognized video/photo/audio formats precede broad preset-name rules; archive/preset and project rules remain conservative |
| A composed English status appeared as “scanDone” | Prevent a short whitespace-prefixed translation fragment from consuming the start of a longer phrase |
| Some copy implied permission had been granted or every unread position merely needed permission | Describe actual unread/system-restricted states without claiming a completed grant; align manual-review copy and installation build numbers |

The access, media and composed-status regressions were observed failing before their fixes. Existing tests were retained; one localization regression was added.

## Automated verification

**806 grouped checks passed** with exit 0, no failure or unavailable/skip result. This retains 751 checks and adds 29 first-use access checks, 25 media-classification checks and one localization check. The standalone **30,017-file complete-list fixture** is separate from that count.

The 126 recovery checks freshly executed **nine actual SIGKILL windows**, covering cleanup, managed data and restore at three operation boundaries. All generated files were restored byte-identically. These are process-termination tests, not physical power-loss tests.

After the complete run, three display-only access messages and their translations were corrected. The language suite was rerun: **27 checks and all 809 catalogue entries passed**. Storage access coverage was rechecked separately. Input-hash comparisons prove that this final follow-up changed only those three message literals and their catalogue entries; all operational control flow stayed identical to the complete run.

## Native first-use walkthrough

A dedicated host used the production interface and cleanup engine with empty, isolated application records. Real UI actions verified:

1. The initial action names its scope: Downloads, cache and logs, 1 MB and larger.
2. A generated directory with denied read permission opens an assistant containing Choose folder, Open System Settings and Recheck. The directory says **Not read yet**, not zero bytes.
3. Rechecking a still-denied directory does not claim success. Closing the assistant leaves a visible unread-location action. The settings action reaches Full Disk Access without changing a toggle.
4. Reopening after the generated permission is restored automatically rescans the same saved scope. All seven fixture files appear, with no selection restored.
5. Adding recommendations selects only an old installer and identified pip cache. Both projects, video and unidentified cache remain unselected. The footage-named MOV appears as video.
6. Manual Select All, project-group deselection, unknown-cache deselection and entering/returning from a file group work. The final review removes the installer group.
7. A mixed batch explicitly displays **two files and total capacity**, identifies its one manual-review item and disables moving until acknowledgment. Back to review resets that acknowledgment.
8. The selected video and pip cache actually move to macOS Trash. A generated conflict at the video's original location disables its restore. The cache restores separately without overwriting the conflicting file.
9. After removing only the generated conflict, rechecking enables the video's restore. **All seven original file hashes match**; both operation-journal entries finish restored, and the projects were never moved.
10. Choosing a folder through the native panel limits the next scan to that folder. The final production app is installed at the original path, opens existing records, displays the corrected English status, and returns to the user's original system-language preference.

The user's actual cleanup history, ignore preferences and journal event payload were unchanged. SQLite header counters can change on ordinary production startup; no byte-identical database claim is made after reopening.

## Boundaries

- Permission denial/recovery used actual POSIX permissions on generated directories. Existing macOS TCC grants were preserved. This does **not** establish a first grant from a fresh macOS account.
- The original public program code was also checked with an isolated Foundation home for fresh scanning. Its OS Trash home does not follow that redirection, so that setup's identity-guard rejection was treated as a test limitation. Cleanup/restore acceptance used the dedicated production-engine host with the ordinary OS Trash resolver; the guard was not relaxed.
- A local launch is **not** another Mac's default Gatekeeper acceptance. The existing assessment setting was not changed; the read-only distribution check still reports a missing notarization ticket.
- Apple Silicon / macOS 27.2 was exercised. Deployment target is macOS 14; actual macOS 14 hardware, another Mac's first launch/permission grant and physical external-drive disconnection remain pending.
- Persistent local signing identity and Hardened Runtime are retained. **No Developer ID signature or Apple notarization.** 1.8.3 app, tag and release assets remain available.

[Machine-readable record](validation-1.8.4-beta.json) · [Installation and permissions](INSTALL.en.md)
