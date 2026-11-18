# 轻扫 Stowfin 1.8.5 Beta

**Apple Silicon · 构建 20 / build 20 · English / 简体中文 · MIT**

项目英文名现为 **Stowfin**。1.8.5 安装包制作于改名前，安装后英文界面显示为 **QingSweep**。  
The project is now **Stowfin**. The 1.8.5 installer predates the rename and displays **QingSweep** in English.

**暂未经过 Apple 公证。** 安装包使用本机签名证书，未使用 Apple Developer ID 签名。macOS 首次启动时可能显示验证提示。  
**This Beta ships without Apple notarization.** It uses a local signing certificate without an Apple Developer ID signature. macOS may show a verification prompt on first launch.

[下载安装包 / Download for Apple Silicon](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.5-beta/QingSweep-1.8.5-beta-arm64.zip) · [中文安装与授权](https://github.com/FishyJ10312/Stowfin/blob/v1.8.5-beta/docs/INSTALL.zh-CN.md) · [English installation and permissions](https://github.com/FishyJ10312/Stowfin/blob/v1.8.5-beta/docs/INSTALL.en.md)

## 本版更新

- **按范围清理。** 从空间分析查看某个应用或文件夹的清理项时，沿用选定范围，并能返回原浏览位置。重启后，自选分析范围会保留。
- **复扫和小缓存。** 「扫描空间与清理项」更新两处结果。停止清理复扫会保留上一次完成的清单和已有勾选。已识别的小缓存可按组查看。
- **选择与复核。** 主按钮复核全部已选，也可以只复核当前范围。空间分析的单个文件详情新增「加入待复核」。
- **恢复状态。** 「清理记录」区分废纸篓暂时无法读取、磁盘未连接和已确认缺失。重新读取后可更新状态，恢复到原位置时会避开重名冲突。

**素材和项目默认不勾选。** 可主动单选、按组或全选，二次确认后才会移到废纸篓。

## What's new

- **Scoped cleanup.** Open cleanup from an application or folder in Storage and return to the same place. Chosen analysis folders stay in scope after a relaunch.
- **Rescans and small caches.** The combined scan updates Storage and Cleanup. Stopping a cleanup rescan keeps the previous completed list and its selections. Recognized small cache files appear in purpose-based groups.
- **Selection and review.** The main button reviews everything you've selected, with a separate option for the current scope. Single-file details in Storage now have an **Add to review** button.
- **Restore status.** History distinguishes unreadable Trash, disconnected volumes and files confirmed missing. Recheck after access returns. Restore skips destinations that are already occupied.

**Media and projects are unselected by default.** You can select them individually, by group or with Select All. Moving them to Trash requires a second confirmation.

## 验证 / Validation

**840 项自动检查通过**，其中 34 项覆盖本版范围、复核与恢复变更。另验证了 30,017 个文件的完整清单。在 macOS 27.2 的 Apple 芯片 Mac 上，用临时文件走通中英文界面，核对了重启范围、跨分类复核、权限重查和恢复。演示文件恢复后的内容一致。磁盘离线以测试路径模拟，其他 Mac 的默认安全设置和 macOS 14 实机仍待验证。

**840 automated checks passed**, including 34 checks for scope, review and restore. A separate 30,017-file fixture verified the complete list. The English and Chinese interfaces were exercised on Apple Silicon running macOS 27.2 with disposable files, covering relaunch, review across scopes, access recheck and byte-for-byte restore. The disconnected-volume case was simulated. First launch on another Mac under default security settings and hardware running macOS 14 are still awaiting validation.

[SHA-256 校验值 / Checksums](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.5-beta/SHA256SUMS.txt) · [机器可读验收记录 / Machine-readable validation](https://github.com/FishyJ10312/Stowfin/blob/v1.8.5-beta/docs/validation-1.8.5-beta.json)

## 中英文界面与演示 / Screenshots and demo

以下截图和清理、恢复演示来自 1.8.2，使用生成的演示文件。  
The screenshots and cleanup/restore demo use generated files and show 1.8.2.

![简体中文清理界面 / Chinese cleanup interface](https://raw.githubusercontent.com/FishyJ10312/Stowfin/a9bab60db54b33f8391dccbacb6a282b4788acae/docs/media/cleanup-zh-CN.png)

![English cleanup interface](https://raw.githubusercontent.com/FishyJ10312/Stowfin/a9bab60db54b33f8391dccbacb6a282b4788acae/docs/media/cleanup-en.png)

[清理与恢复演示 / Cleanup and restore demo](https://github.com/FishyJ10312/Stowfin/blob/v1.8.5-beta/docs/DEMO.md)
