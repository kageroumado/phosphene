# Phosphene

[English](README.md) · [简体中文](README.zh-CN.md)

Phosphene 通过与 Apple 航拍墙纸相同的墙纸管线，把你的视频添加到“系统设置”→“墙纸”。macOS 会在桌面和锁定屏幕上播放它们，即使退出 App 之后也一样。它还能把 Steam 创意工坊里的 **Wallpaper Engine** 壁纸变成视频墙纸。

<a href="https://kagerou.glass/get/phosphene?from=readme"><img src=".github/download.zh-CN.svg" alt="下载 Mac 版 Phosphene" width="360" height="80"></a>

上方按钮下载的是上游发行版。要体验此分支的明暗配对和转换工具，请参阅[从源码构建](CONTRIBUTING.md#build)。

![“系统设置”→“墙纸”中的 Phosphene 视频](.github/phosphene-settings.zh-CN.png)

## 特色

- 使用 Steam 创意工坊里的 Wallpaper Engine 壁纸：在 Steam 里订阅，Phosphene 为每一张做出循环视频。
- 将两段视频配成一张墙纸，随 Mac 的浅色或深色外观自动切换。[创建明暗墙纸配对](#明暗墙纸配对)
- 播放 HDR 视频时可以保留明亮的高光，也可以调得柔和一些，或导出 SDR 副本。[了解 HDR 与 SDR](#hdr-与-sdr)
- 退出 Phosphene 后，桌面和锁定屏幕继续播放。
- 桌面被遮挡时暂停播放，并根据电源和温度状况调整解码。

<details>
<summary>完整功能</summary>

- 通过**资料库**导入视频，在**“系统设置”→“墙纸”**中选择。
- 可按显示器或空间分别选择墙纸，也可**仅在锁定屏幕**播放。
- 桌面和锁定屏幕播放均通过 macOS 墙纸管线完成。
- 支持 MP4、MOV 及其他 AVFoundation 可读取的格式；无缝循环，锁定与解锁平滑过渡。
- 菜单栏预览、暂停、显示器切换，以及登录时打开。
- 墙纸卡住时，从菜单栏**重新启动墙纸代理**。
- **Wallpaper Engine** 分区：Sevoflurane、CrossOver 或 Whisky 里的 Steam 创意工坊下载，变成循环视频。

</details>

## 明暗墙纸配对

同一段动画可以分别渲染成日景和夜景。配对后，资料库和 macOS 墙纸设置都只显示一张墙纸。切换外观时，另一段视频会从动画的对应位置接上。

1. 导入两段视频，在 **资料库 → 所有视频** 中同时选中它们，然后选择 **配对…**。
2. 确认预览里左边是浅色版、右边是深色版。如果顺序反了，可以交换，再点 **创建配对**。直接配对会复用已有文件，无需重新编码。
3. 打开 **系统设置 → 墙纸**，选中这组墙纸。选 **自动** 会跟随 Mac 的系统外观。选 **浅色** 或 **深色** 则会固定播放对应版本。

直接配对要求两段视频的分辨率、画面方向、帧率、帧数、时长和编码格式（含色彩格式）一致。开头必须是共同关键帧，此后相邻共同关键帧的间隔最多为半秒。配对窗口左下角的 **?** 列出了具体导出要求。

如果规格不匹配，点 **打开配对转换工具…** 就能带入这两段视频并保留明暗顺序。也可以从 **工具 → 明暗配对转换工具…** 直接打开。选好共同的分辨率、帧率和色彩格式后，工具会对齐关键帧，取较短一段的时长，生成新配对并加入资料库。

在资料库的 **明暗配对** 分类里可以找到已配对的墙纸。选择 **拆分配对…**，两段视频会恢复为独立条目。对于有运动的画面，还可以在 **设置 → 播放** 中开启 **Blend Matching Frames**，在切换期间混合同一时间戳的明暗帧。这会短暂增加 GPU 和内存占用，高帧率 HDR 视频尤为明显。

## HDR 与 SDR

**Phosphene → 设置 → 播放 → 动态范围** 只影响播放时的显示效果，控制墙纸和视频预览中的高光能有多亮。配对的 **浅色** 和 **深色** 决定播放哪段视频。例如，深色版的夜空也可以用 HDR 表现明亮的星星。

| 播放设置 | 播放 HDR 视频时的效果 |
| --- | --- |
| 自动（默认） | 由 macOS 选择显示范围。 |
| 标准 | 将画面亮度限制在 SDR 范围内。 |
| 受限高动态范围 | 保留部分 HDR 高光，与桌面窗口并排显示时更柔和。 |
| 高 | 请求使用显示器当前可提供的完整 HDR 范围。 |

高光实际能有多亮，取决于片源记录的细节，以及显示器当前在 SDR 白色之上还剩多少亮度空间。[Apple 的 HDR 显示说明](https://developer.apple.com/documentation/coregraphics/adopting-advancements-in-hdr-image-rendering)

### 转换视频文件

- **优化** 会为单个视频或整组配对生成节能播放版本，并保留原片。Phosphene 可根据电源和温度状况选用这些副本。受支持的 HLG 和 PQ 片源默认保留 HDR。要生成 SDR 副本，先勾选 **转换为 SDR**，再选择优化预设。
- **工具 → 自定义转换…** 支持资料库视频和外部文件。输出可以选择 **SDR · Rec. 709**、**HDR · HLG** 或 **HDR · PQ**。明暗配对转换工具为两段视频共用同一输出格式。HDR 输出使用 10 位 HEVC。HDR 转 SDR 时，高光会映射到 SDR 亮度范围内。将 SDR 导出为 HDR，也只能保留原片已有的高光细节。

## Wallpaper Engine

![Phosphene 资料库的 Wallpaper Engine 分区，Steam 创意工坊的下载内容等待制作成视频](.github/phosphene-library.zh-CN.png)

Steam 创意工坊里有几十万张为 Wallpaper Engine 制作的动态壁纸，而它是一个 Windows 程序。Phosphene 把它们变成视频墙纸：在 Steam 里订阅，在资料库的 Wallpaper Engine 分区里选中，然后点“制作视频”。

Wallpaper Engine 在 Windows 版 Steam 里运行。[Sevoflurane](https://kagerou.glass/sevoflurane/zh-CN/?from=phosphene-readme) 能把这个 Steam 带到 Mac 上，免费，出自同一位开发者。视频保留什么、省略什么：[WALLPAPER-ENGINE.md](WALLPAPER-ENGINE.md)。

Wallpaper Engine 是 Wallpaper Engine Team 的商标；Steam 是 Valve Corporation 的商标。Phosphene 是独立开发的 App。

## 隐私

在菜单栏选择**算我一个**即可开启匿名使用统计。你也可以在**设置 → 隐私**中分别更改以下两项，默认均关闭。

- **发送崩溃报告**会在 Phosphene 崩溃后发送崩溃日志及基本系统信息。上传前会隐去账户名称、Mac 名称和个人文件夹路径。
- **统计这台 Mac** 会在使用当天发送一次匿名签到，包括日期、App 与 macOS 版本、芯片、内存、语言、显示器数量、过去一周的使用天数，以及是否导入过视频。视频名称和文件均不在统计范围内。

关闭两项设置会请求删除这台 Mac 已发送的数据。如果服务暂时不可用，App 会重试。[Digoxin 字段说明（英文）](https://github.com/kageroumado/digoxin/blob/main/REFERENCE.md)。

## 其他信息

- macOS 26+ · Apple 芯片或 Intel。
- Homebrew：`brew install --cask phosphene`。
- 使用私有的 `WallpaperExtensionKit` API，macOS 更新可能改变其行为。[故障排除与实现细节](REFERENCE.md)（英文）。
