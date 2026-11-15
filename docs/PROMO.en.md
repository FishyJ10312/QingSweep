# QingSweep 1.8.2 Beta launch copy

## Short post

I built QingSweep, a local Mac storage browser and cleanup tool, and have released 1.8.2 Beta with English and Simplified Chinese.

See storage by application or folder, review installers and cache separately from personal files, and decide what moves to Trash. Media and projects start unselected. You can select them manually, review again and restore eligible files by batch from History.

The code is MIT licensed. Scans and cleanup records stay on your Mac. This Beta is for Apple Silicon and has not been notarized by Apple, so read the installation guide and start with a disposable folder.

Download and source: https://github.com/FishyJ10312/QingSweep

## Longer post

When my Mac's storage filled up, I wanted to see which applications and folders were using the space before deciding what to remove. That became QingSweep.

1.8.2 Beta now includes English and Simplified Chinese in one app:

- Browse by application or folder, search the scanned index and return to parent folders.
- Review Recommended, Choose manually and Manual review groups separately.
- Keep media and projects unselected by default, with individual, group and Select All controls when you decide to include them.
- Confirm the list before moving anything to Trash. Restore eligible files by batch without overwriting existing files.
- Keep scans, history and per-file operation journals locally, with restart reconciliation for interrupted operations.

This release adds the MIT license and bilingual documentation. 650 checks passed locally. We also walked through the English interface with generated files, moved one to Trash and restored it, then verified the original bytes.

It's still a Beta: Apple Silicon only, built for macOS 14 or later and actually tested on macOS 27.2. It is not Developer ID signed or notarized. First launch on another Mac with default Gatekeeper and more external-drive scenarios still need testing.

Try a disposable folder first. Feedback on installation, permissions, classification, translation and restore is welcome. Please redact private filenames and paths in reports.

https://github.com/FishyJ10312/QingSweep/releases/tag/v1.8.2-beta

## Repository description

Local macOS storage analysis and review-first cleanup. English / 简体中文. MIT. Media and projects unselected by default; batch restore. Beta, not notarized.
