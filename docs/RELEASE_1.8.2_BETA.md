# QingSweep 1.8.2 Beta · English & 简体中文

Local macOS storage analysis and review-first cleanup. **MIT licensed.** Apple Silicon / arm64, deployment target macOS 14 or later; tested on macOS 27.2.

## What changed

- English and Simplified Chinese in one app. Follow the system or choose a language in the top menu; preferences survive relaunch.
- Translated cleanup groups, classification and impact details, access guidance, storage browsing, tools, history and restore results.
- Original filenames, paths, saved scan identities and cleanup history remain unchanged. English search also finds previously indexed Chinese category titles.
- Added the MIT license, bilingual README, installation/privacy/validation guides and English issue template.
- Retained manual selection, second confirmation, per-file journaling and restart reconciliation. **Media and projects stay unselected by default.**

650 checks passed, including 26 localization checks; all 787 catalogue messages were exercised separately. The English native flow was actually walked through using generated files: select, deselect the project, review, confirm, move to Trash and restore. Restored bytes matched the originals.

## Downloads

- `QingSweep-1.8.2-beta-arm64.zip` — bilingual application; the bundle filename remains `轻扫.app` for upgrade continuity.
- `QingSweep-1.8.2-beta-source.zip` — curated MIT-licensed source and documentation.
- `INSTALL.en.md` / `INSTALL.zh-CN.md` — first launch, permissions, language and upgrade instructions.
- `SHA256SUMS.txt` — download integrity checks.

**Not Developer ID signed or notarized by Apple.** macOS may require the per-app “Open Anyway” action after your first attempt. Do not disable Gatekeeper globally. See [English installation](https://github.com/FishyJ10312/QingSweep/blob/main/docs/INSTALL.en.md) or [中文安装说明](https://github.com/FishyJ10312/QingSweep/blob/main/docs/INSTALL.zh-CN.md).

Cleanup moves files to Trash and never empties it. Moved bytes are not immediately freed disk space. Restore requires the corresponding files to remain in Trash and pass verification. Test a disposable folder first. Another Mac under default Gatekeeper, actual macOS 14 hardware and physical external-drive disconnection remain unverified.

[English README](https://github.com/FishyJ10312/QingSweep#readme) · [Validation](https://github.com/FishyJ10312/QingSweep/blob/main/docs/VALIDATION.en.md) · [MIT License](https://github.com/FishyJ10312/QingSweep/blob/main/LICENSE)

---

## 中文

轻扫 1.8.2 Beta 新增完整英文界面，默认跟随系统，也可在顶部切换 English / 简体中文。文件名、路径、原有索引和清理记录的身份保持不变，旧中文索引也支持英文分类搜索。

补齐 MIT License、双语 README、安装授权与隐私说明、验证记录和英文反馈模板。保留 1.8.1 发布与备份。

**素材和项目默认不勾选**，仍可手动单选、按组或全选，经复核和二次确认后移到废纸篓。应用不会清空废纸篓，移入容量不代表已释放空间。

本机 650 项检查通过，另检查 787 条英文消息；英文原生界面已用临时文件实际走通选择、取消项目、确认、清理和批次恢复，恢复字节一致。原有 9 个强制退出窗口检查保留。

**当前为 Beta，暂未 Developer ID 签名或 Apple 公证。** 面向 Apple Silicon，最低编译版本 macOS 14，实机验收在 macOS 27.2。其他 Mac 的默认安全设置首次启动、macOS 14 实机及真实外置盘拔插仍待验证。
