# Phosphene

[English](README.md) · [简体中文](README.zh-CN.md)

Phosphene 通过与 Apple 航拍墙纸相同的墙纸管线，把你的视频添加到“系统设置”→“墙纸”。macOS 会在桌面和锁定屏幕上播放它们，即使退出 App 之后也一样。

<a href="https://kagerou.glass/get/phosphene?from=readme"><img src=".github/download.zh-CN.svg" alt="下载 Mac 版 Phosphene" width="360" height="80"></a>

![“系统设置”→“墙纸”中的 Phosphene 视频](.github/phosphene-settings.zh-CN.png)

## 特色

- 在“系统设置”中，与 Apple 自带墙纸并列选择个人视频。
- 退出 Phosphene 后，桌面和锁定屏幕继续播放。
- 桌面被遮挡时暂停播放，并根据电源和温度状况调整解码。
- 把 Steam 创意工坊里的 Wallpaper Engine 壁纸做成循环视频。

<details>
<summary>完整功能</summary>

- 通过**资料库**导入视频，在**“系统设置”→“墙纸”**中选择。
- 可按显示器或空间分别选择墙纸，也可**仅在锁定屏幕**播放。
- 桌面和锁定屏幕播放均通过 macOS 墙纸管线完成。
- 支持 MP4、MOV 及其他 AVFoundation 可读取的格式；无缝循环，锁定与解锁平滑过渡。
- 菜单栏预览、暂停、显示器切换，以及登录时打开。
- 根据可见性、电源和温度调整播放；可选生成低分辨率版本。
- 墙纸卡住时，从菜单栏**重新启动墙纸代理**。
- **Wallpaper Engine** 分区：自动找到 Sevoflurane、CrossOver 或 Whisky 里的 Steam 创意工坊下载，把场景和视频渲染成循环的 HEVC 或 H.264 视频，循环长度自动判断。

</details>

## Wallpaper Engine

Wallpaper Engine 的创意工坊里有几十万张动态壁纸，但它是一个 Windows 程序。Phosphene 读取它的下载内容，用 Wallpaper Engine 自己的着色器把每个场景渲染成循环视频，之后就和普通视频墙纸一样播放。Wallpaper Engine 本身在 Windows 版 Steam 里运行：[Sevoflurane](https://kagerou.glass/sevoflurane/zh-CN/?from=phosphene-readme) 能在 Mac 上运行这个 Steam，免费，出自同一位开发者。在那里订阅壁纸，它们就会出现在 Phosphene 的资料库里。工作原理和尚未支持的内容：[WALLPAPER-ENGINE.md](WALLPAPER-ENGINE.md)。

Wallpaper Engine 是 Wallpaper Engine Team 的商标；Steam 是 Valve Corporation 的商标。Phosphene 是独立开发的 App。

## 统计

除非你同意，否则不会发送任何内容。菜单栏会询问一次是否统计这台 Mac；如果你选择加入，Phosphene 会在你使用它的每一天发送一次匿名签到：Phosphene 和 macOS 的版本、芯片系列和内存大小、语言和日期、最近 7 天中使用了几天、是否有自己的视频，以及显示器数量。它从不包含你使用的是哪些视频，其中也没有任何能指认你的信息。更高一档会在 Phosphene 本身崩溃时附上一份已清理的报告。关闭后会删除这台 Mac 发送过的所有内容。所有字段见 [Digoxin 参考文档](https://github.com/kageroumado/digoxin/blob/main/REFERENCE.md)（英文）。

## 其他信息

- macOS 26+ · Apple 芯片或 Intel。
- Homebrew：`brew install --cask phosphene`。
- 使用私有的 `WallpaperExtensionKit` API，macOS 更新可能改变其行为。[故障排除与实现细节](REFERENCE.md)（英文）。
