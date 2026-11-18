# 轻扫 QingSweep 1.8.4 Beta

**看清 Mac 空间占用，确认以后再清理。**  
**See what uses your Mac's storage. Review before you clean.**

English / 简体中文 · MIT · Apple Silicon · **Beta，暂未 Developer ID 签名或 Apple 公证 / Not Developer ID signed or notarized.**

[下载安装包 / Download](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.4-beta/QingSweep-1.8.4-beta-arm64.zip) · [中文安装授权](https://github.com/FishyJ10312/Stowfin/blob/main/docs/INSTALL.zh-CN.md) · [English installation](https://github.com/FishyJ10312/Stowfin/blob/main/docs/INSTALL.en.md)

## 首次使用修复 / First-use fixes

- **授权入口**：读取失败直接提供选择文件夹、系统设置、实际重查；重开后确认恢复访问才按保存范围补扫。
- **分类边界**：已知视频、照片、音频不再被 footage、素材等名称关键词覆盖；未知缓存和安装包明确由用户自行确认。
- **清晰提示**：首次按钮写明常用位置与 1 MB 起；不凭未读位置推断授权成功，不把系统限制概括为只差授权，修正英文组合状态。

- **Access recovery:** actionable unread locations, folder selection, System Settings and real rechecks. Relaunch rescans the saved scope only after actual access recovers.
- **Classification:** known media formats keep their type despite filename keywords. Unidentified cache and installers remain manual-review choices.
- **Clear scope and status:** the first scan names common locations and its minimum size. Access messages do not claim an unverified grant; composed English statuses remain readable.

**素材和项目默认不勾选。** 可以手动单选、按组或全选；复核及二次确认后才移到废纸篓。恢复不会覆盖原位置已有文件。  
**Media and projects start unselected.** Manual selection supports individual files, groups and Select All, followed by review and a second confirmation. Restore never overwrites an existing destination.

## 验证 / Validation

版本 **1.8.4（19）**：806 项分组回归通过，另有 30,017 文件清单、9 个真实强制退出恢复窗口，最终复核 809 条英文消息。原生新用户流程用临时目录验证拒绝、恢复访问、重开补扫、选择范围、取消选择、确认和冲突恢复；2 项文件实际清理并恢复，7 项原文件哈希一致。保留 1.8.3 标签与发布附件。

Build **1.8.4 (19)**: 806 grouped checks, a separate 30,017-file list and nine real SIGKILL recovery windows. The final language check covers 809 entries. Native fixture walkthroughs verify access recovery, scope, deselection, confirmation and non-overwriting restore. Two files were actually moved/restored, and all seven original fixture hashes matched. The 1.8.3 tag and assets are retained.

[中文完整验证及限制](https://github.com/FishyJ10312/Stowfin/blob/main/docs/VALIDATION.zh-CN.md) · [Full English validation and limits](https://github.com/FishyJ10312/Stowfin/blob/main/docs/VALIDATION.en.md)

这仍是本机隔离资料验收，**另一台 Mac 默认安全设置首次启动、全新系统账号首次授权、macOS 14 实机及真实外置盘拔插仍待验证**。授权由用户本人完成，不需要关闭整个系统安全检查。

This is same-Mac isolated-data acceptance. **Another Mac under default Gatekeeper, a fresh macOS account's first grant, actual macOS 14 hardware and physical drive disconnection remain unverified.** System permission changes remain under the user's control.

## 界面与演示 / Gallery and demo

现有中英文图库和演示录制于 1.8.2，仅使用生成文件。1.8.4 延续相同的选择、复核、废纸篓和批次恢复流程；本次访问助手与分类修复有单独的原生验收记录。

The existing bilingual gallery was recorded with 1.8.2 using generated files. The selection, review, Trash and batch-restore workflow is retained; this patch has separate native acceptance evidence.

![English cleanup with generated files](https://raw.githubusercontent.com/FishyJ10312/Stowfin/a9bab60db54b33f8391dccbacb6a282b4788acae/docs/media/cleanup-en.png)

![简体中文清理，仅使用临时文件](https://raw.githubusercontent.com/FishyJ10312/Stowfin/a9bab60db54b33f8391dccbacb6a282b4788acae/docs/media/cleanup-zh-CN.png)

[清理与恢复演示 / Cleanup and restore demo](https://github.com/FishyJ10312/Stowfin/blob/main/docs/DEMO.md)

移到废纸篓不会立即释放对应空间。恢复依赖文件仍在废纸篓且通过核验，不能替代备份。  
Moving to Trash does not immediately free that space. Restore requires the file to remain available and pass checks; it is not a backup.

## 分享 / Share

轻扫 QingSweep 1.8.4 Beta：本地分析 Mac 空间，确认以后再清理。中英文、MIT 开源，完善首次授权与补扫、素材分类、清理确认和批次恢复。素材和项目默认不勾选。Apple Silicon 测试版，暂未 Apple 公证。

QingSweep 1.8.4 Beta: local Mac storage analysis, review-first cleanup and batch restore. English / 简体中文, MIT. Improved first-use access and media classification; media and projects start unselected. Apple Silicon Beta, not Apple-notarized.

[下载与演示 / Download and demos](https://github.com/FishyJ10312/Stowfin/releases/tag/v1.8.4-beta)
