# 轻扫 QingSweep 1.8.3 Beta

**看清 Mac 空间占用，确认以后再清理。**  
**See what uses your Mac’s storage. Review before you clean.**

English / 简体中文 · MIT · Apple Silicon · 本地运行 / Local processing  
**Beta：暂未 Developer ID 签名或 Apple 公证 / Not Developer ID signed or Apple-notarized.**

[下载安装包 / Download app](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.3-beta/QingSweep-1.8.3-beta-arm64.zip) · [中文安装授权说明](https://github.com/FishyJ10312/Stowfin/blob/main/docs/INSTALL.zh-CN.md) · [English installation](https://github.com/FishyJ10312/Stowfin/blob/main/docs/INSTALL.en.md)

## 本版修复 / Fixes

- **副本重试核验**：重新检查当前来源与保留副本的内容和文件身份；来源已改、证明失效时跳过，仍须重新确认。
- **启动项回滚**：读取系统实际的停用与载入状态；操作取消或失败后恢复原状态并再次核验，失败会明确提示。
- **扫描范围补齐**：“分析全部位置”会补齐默认位置并保留原有自选目录；普通更新与当前范围完整重扫继续沿用原范围。

- **Retained-copy retry:** checks current source and kept-copy content and identity again. A changed source cannot reuse an older proof; retry still requires fresh review.
- **Login-item rollback:** uses the actual disabled/loaded state, restores it after cancellation or failure, and verifies recovery. Unresolved recovery is reported.
- **Scan coverage:** “Analyze all locations” expands default locations while retaining chosen folders. Ordinary updates and current-scope full rescans preserve the current scope.

素材和项目继续默认不勾选；可以手动单选、按组选择或全选，复核及二次确认后移到废纸篓。不会自动清空废纸篓。  
Media and projects start unselected. Select individually, by group or with Select All; including them requires review and a second confirmation. Cleanup moves files to Trash and never empties it.

## 中英文界面与演示 / Bilingual gallery and demo

以下画面录制于 1.8.2，全部使用临时文件。1.8.3 延续相同的选择、复核、清理与恢复流程；本次修复另有临时夹具验收。  
These captures were recorded with 1.8.2 using generated files. The selection, review, Trash and restore workflow is retained in 1.8.3; this patch is verified separately with disposable fixtures.

![English cleanup interface with generated files](https://raw.githubusercontent.com/FishyJ10312/Stowfin/a9bab60db54b33f8391dccbacb6a282b4788acae/docs/media/cleanup-en.png)

![简体中文清理界面，仅使用临时文件](https://raw.githubusercontent.com/FishyJ10312/Stowfin/a9bab60db54b33f8391dccbacb6a282b4788acae/docs/media/cleanup-zh-CN.png)

![English cleanup and batch restore demo using disposable files](https://raw.githubusercontent.com/FishyJ10312/Stowfin/a9bab60db54b33f8391dccbacb6a282b4788acae/docs/media/cleanup-restore-en.gif)

[中文清理与恢复演示 / Chinese demo](https://github.com/FishyJ10312/Stowfin/blob/main/docs/DEMO.md) · [中英文宣传素材包 / Existing bilingual media kit (1.8.2)](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.2-beta/QingSweep-1.8.2-beta-media-kit.zip)

## 验证与边界 / Validation and limits

应用版本 **1.8.3（18）**。自动检查与本机临时文件流程的完整结果见[中文验证记录](https://github.com/FishyJ10312/Stowfin/blob/main/docs/VALIDATION.zh-CN.md)、[English validation](https://github.com/FishyJ10312/Stowfin/blob/main/docs/VALIDATION.en.md)及附件。1.8.2 的标签和发布附件保留。

App **1.8.3 (18)**. Full automated and native fixture results are recorded in the linked validation notes and attached report. The 1.8.2 tag and release assets are preserved.

最低编译版本 macOS 14；实机为 Apple Silicon / macOS 27.2。另一台 Mac 的默认 Gatekeeper 首次启动、macOS 14 实机和真实外置盘拔插仍待验证，因此继续作为 Beta / Pre-release。

Built for macOS 14 or later and exercised on Apple Silicon / macOS 27.2. Another Mac under default Gatekeeper, actual macOS 14 hardware and physical external-drive disconnection remain unverified. This remains a Beta / Pre-release.

移到废纸篓的容量不等于立即释放空间。恢复依赖文件仍在废纸篓并通过校验，不覆盖现有文件，也不能替代备份。  
Moved bytes are not immediately freed space. Restore requires the corresponding file to remain in Trash and pass verification, never overwrites an existing destination, and is not a backup.

## 分享文案 / Ready-to-share copy

轻扫 QingSweep 1.8.3 Beta：本地分析 Mac 空间，确认以后再清理。支持中英文、分类清单和批次恢复；素材和项目默认不勾选。本版修复副本重试、启动项回滚和完整扫描范围。MIT 开源，Apple Silicon 测试版，暂未 Apple 公证。

QingSweep 1.8.3 Beta: local Mac storage analysis, review-first cleanup and batch restore. English / 简体中文, MIT. Media and projects start unselected. This patch fixes retained-copy retry, login-item rollback and full scan coverage. Apple Silicon Beta, not Apple-notarized.

[下载与演示 / Download and demos](https://github.com/FishyJ10312/Stowfin/releases/tag/v1.8.3-beta)
