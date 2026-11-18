# Screenshots and demos / 截图与演示

QingSweep 1.8.2 Beta · Captured on 2026-11-15.

## English

- [Cleanup interface](media/cleanup-en.png)
- [Media and project defaults](media/manual-review-en.png)
- [Batch history](media/history-en.png)
- [Animated step-by-step demo](media/cleanup-restore-en.gif)
- [MP4 for sharing](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.2-beta/cleanup-restore-en.mp4)

## 简体中文

- [清理界面](media/cleanup-zh-CN.png)
- [素材和项目默认不勾选](media/manual-review-zh-CN.png)
- [清理批次与恢复](media/history-zh-CN.png)
- [分步演示动图](media/cleanup-restore-zh-CN.gif)
- [方便转发的 MP4](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.2-beta/cleanup-restore-zh-CN.mp4)

## How these were made / 制作方式

The production SwiftUI views, classification rules and cleanup/restore engine ran in a dedicated native host with a separate temporary home directory. Only generated files and a dummy application metadata fixture were supplied. The installer and cache are disposable byte fixtures; they are not usable installation packages. No personal scan or cleanup database was loaded.

Both languages were operated through the actual native interface. Two generated candidates were selected, reviewed, moved to Trash and restored from their batch. The generated media, project and notes remained unselected. All six generated files were checked against their original bytes after restore.

The host exported its own view images, without capturing the desktop or other windows. The animations sequence those captures with explanatory captions and edited hold times; they are **not real-time screen recordings or performance benchmarks**. App text and operation results in the captures were not replaced. File/path details remain collapsed. Names shown are examples, and no personal filenames, usernames or private paths are included. Displayed capacity changes are incidental device readings, not a promise of space reclaimed.

演示使用正式界面与分类、清理、恢复引擎，在独立原生演示程序和临时目录中运行。输入全部为生成的文件与虚拟应用元数据；安装包和缓存只是可丢弃的字节夹具，不能用于安装软件。没有载入个人扫描库或清理记录。

中英文均通过实际界面操作：选择两项候选、复核、移入废纸篓、批次恢复。素材、项目和笔记未勾选，恢复后六个文件均与原始字节核验一致。

程序只导出自己的界面，不录制桌面和其他窗口。动图与 MP4 是这些画面的分步展示，停留时长经过调整，**不是实时录屏或性能测试**。未替换界面文字或操作结果；路径详情保持收起，文件名均为通用演示名称。画面的磁盘可用空间变化是当时读数，不代表清理能释放的空间。

The images and narration follow the repository's [MIT License](../LICENSE); project attribution remains in [NOTICE.md](../NOTICE.md).

[Release gallery / 发布页截图与演示](https://github.com/FishyJ10312/Stowfin/releases/tag/v1.8.2-beta) · [Media kit / 宣传素材包](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.2-beta/QingSweep-1.8.2-beta-media-kit.zip)
