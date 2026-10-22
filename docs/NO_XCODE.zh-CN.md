# Windows：下载空壳，在本机完成编译与组装

本流程不要求你拥有 Mac 或本地 Xcode。公开空壳由 GitHub 的 Mac 机器编译；**游戏文件及其派生代码始终留在你自己的 Windows 电脑**。

## 1. 准备工具

- Git、Python 3.11 或更新版本。
- Rust / rustup，安装固定的 GNU 工具链：

```powershell
rustup toolchain install 1.99.1-x86_64-pc-windows-gnu --profile minimal
```

- [LLVM-MinGW](https://github.com/mstorsjo/llvm-mingw/releases/tag/20261006) 的 `llvm-mingw-20261006-ucrt-x86_64` Windows 包。解压，例如 `C:/tools/llvm-mingw`；确认 `bin` 内有 `clang.exe`、`gcc.exe`、`ld.lld.exe`。
- 预留至少 6 GB 磁盘空间；建议 16 GB 内存。重编译耗时随 CPU、内存及并发数变化。

工具会为 Rust GNU 链接补充 Rust 自带运行库，不需要复制 Apple SDK。仓库中的 C 标准库声明和链接描述是最小接口声明，不是 Apple SDK。

## 2. 获取项目与空壳

```powershell
git clone https://github.com/yunzhe2763991572-byte/rhythm-heaven-3ds-ios-shell.git
cd rhythm-heaven-3ds-ios-shell
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt
```

从本项目 Releases 下载 `RhythmHeaven3DS-shell.ipa`，放到自己创建的 `input/` 目录。再把自己的受支持 CIA 放到 `input/game.cia`。它必须满足 [版本要求](GAME_FILES.zh-CN.md)。不要把这些文件提交到 Git。

## 3. 在本机生成 iOS 游戏框架

```powershell
.venv/Scripts/python tools/prepare_game.py --game input/game.cia --llvm-bin C:/tools/llvm-mingw/bin --jobs 4
```

该命令会校验原文件，下载固定版本公开依赖，生成私有 C 代码，并编译 228 个 iOS 单元，得到 `build/private-game/ios/Guest.framework`。不会上传游戏，不会修改原始 CIA。内存不足时改成 `--jobs 2`。

生成阶段完成但 C 编译被中断时，可以接着编译，已完成且校验一致的对象会复用：

```powershell
.venv/Scripts/python tools/build_guest.py --source build/private-game/aot --output build/private-game/ios --llvm-bin C:/tools/llvm-mingw/bin --jobs 4
```

已存在最终 Guest.framework 时不要重新覆盖；继续下面的打包步骤即可。要彻底重建，请使用新的项目目录，保留旧结果。

## 4. 准备开放字体

```powershell
.venv/Scripts/python tools/prepare_font.py
```

仅从固定版本 Google Fonts 下载 Noto Sans JP 与 OFL 许可，校验 SHA256，生成字重 500 的静态字体并使用新的字体名称。无需 Nintendo 系统字体。

## 5. 在本机生成完整 IPA

```powershell
.venv/Scripts/python tools/pack_ipa.py --shell input/RhythmHeaven3DS-shell.ipa --game input/game.cia --guest build/private-game/ios/Guest.framework --font build/open-font --output output/my-local-build
```

结果为 `output/my-local-build/RhythmHeaven3DS-local.ipa`，以及本地哈希核验报告。该包包含你的游戏和派生代码，应保留在本机；不要把它添加到公开仓库或公开 Release。

## 6. 签名与安装

使用自己的 iLoader 等工具签名安装本机生成的完整 IPA。这里的空壳／组装 IPA 不带个人分发证书。

更新前备份应用文档里的 `user` 存档。使用同一账户和同一应用标识覆盖安装；不要在备份完成前卸载旧应用。首次安装按系统提示信任开发者并完成设备上的必要设置。

## 常见情况

- **只有 Windows 和 iPhone**：可下载 Release 空壳或 Fork 后通过 Actions 编译空壳，其他步骤在 Windows 本地执行。
- **空壳提示没有资源**：这是预期行为。要先在电脑完成第 3～5 步，然后安装完整包。
- **版本／哈希不匹配**：停止并核对自己的输入，不会尝试修改或破解文件。
- **资源路径／依赖下载失败**：保留已经完成的本机结果，恢复网络后继续；不要把游戏包上传给在线编译服务。
- **字体下载失败**：恢复对 `raw.githubusercontent.com` 的访问后重试。已下载文件会在使用前校验。
