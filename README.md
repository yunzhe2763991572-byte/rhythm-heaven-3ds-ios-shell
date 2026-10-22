# Rhythm Heaven 3DS · iOS Shell

3DS《节奏天国 The Best＋ / Rhythm Heaven Megamix》日版的 iPhone 适配源码、**不含游戏资源的空壳 IPA**，以及本机重编译、组装工具。

采用 **AOT 提前编译＋Zakuro 兼容运行库＋解释器回退**，通过 MoltenVK 调用 Metal。无需在手机上开启 CPU JIT；没有完整反编译或重写游戏。GPU 仍使用正常的着色器编译流程。

## 下载与开始

1. 从 [Releases](https://github.com/yunzhe2763991572-byte/rhythm-heaven-3ds-ios-shell/releases) 下载 `RhythmHeaven3DS-shell.ipa`。
2. 克隆本仓库，按 [Windows / 无本地 Xcode 指南](docs/NO_XCODE.zh-CN.md) 在自己的电脑生成游戏框架、组装完整 IPA。
3. 游戏输入必须符合 [文件与版本要求](docs/GAME_FILES.zh-CN.md)。仅安装空壳不能启动游戏，也不能只向手机复制一份 CIA 来完成配置。

**本仓库与 Release 不提供游戏本体、RomFS、ExeFS、游戏图标、Nintendo 系统字体、存档、密钥、生成的游戏 C 代码、Guest.framework 或完整游戏 IPA。**

## 手机操作

- 横屏：主屏居中放大，左上小屏可点按，与主屏交换大小；副屏放大后可触摸。
- 竖屏：双屏上下排列；放大的四向键和 A 键。
- 大 A / 并排 A、B 两种布局一键切换，自动记忆选择。
- 横屏切换入口在右上；竖屏切换入口在左下，实际画面帧数在右下。
- 保留 START / SELECT；竖屏另有暂停。L/R 不显示。

最低构建目标为 iOS 16，已验证的完整本机版本使用 A19 Pro 设备。其他机型、系统和所有关卡没有得到全面验证，不承诺持续 60 帧。仍有缺少 Mii 资源、部分特殊字符及偶发短卡顿等限制；当前配置没有汉化。

## 构建边界

| 阶段 | 输入 | 位置 | 输出 |
|---|---|---|---|
| 编译空壳 | 本仓库通用源码、固定版本公开依赖 | GitHub Actions 或 Mac | 无游戏资源的 shell IPA |
| 编译游戏 | 使用者自己的受支持解密 CIA | **本机** | 私有生成 C 与 Guest.framework |
| 准备字体 | 固定版本 Noto Sans JP 开放字体 | 本机 | OFL 字体 |
| 组装 | 空壳＋自有 CIA＋本机 Guest＋开放字体 | **本机** | 个人使用的完整 IPA |

Actions 只有“编译空壳”，没有游戏上传入口。`build/`、`work/`、`input/`、`output/` 和常见游戏／密钥／二进制格式被 Git 忽略。公开发布前运行 `python tools/audit_public.py`，空壳发布前运行 `python tools/audit_shell.py <shell.ipa>`。

## 自行编译空壳

Fork 后在 Actions 运行 **Build content-free iOS shell**，成功后下载 artifact。该过程不需要游戏文件。详细环境与本地 Mac 命令见 [构建指南](docs/BUILD.zh-CN.md)。

## 来源与许可

- [fearkov/3dsrecomp](https://github.com/fearkov/3dsrecomp)：静态重编译工具与 ABI。
- [fearkov/Zakuro](https://github.com/fearkov/zakuro)：3DS 系统、图形、声音及解释器运行库。
- [KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK)：Vulkan 到 Metal 的图形实现。
- [google/fonts · Noto Sans JP](https://github.com/google/fonts/tree/main/ofl/notosansjp)：本机准备的开放字体。

项目自有适配代码采用 MIT；依赖保留各自许可，见 [第三方说明](THIRD_PARTY_NOTICES.md)。不包含官方游戏源码或游戏资源，与任天堂没有关联。
