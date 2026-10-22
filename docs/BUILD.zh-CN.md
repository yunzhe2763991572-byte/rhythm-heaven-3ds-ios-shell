# 通用空壳构建与版本固定

## 固定依赖

| 依赖 | 版本或提交 |
|---|---|
| Rust | `1.99.1` |
| Xcode | `26.6` |
| iOS deployment target | `16.0`，物理 ARM64 |
| Zakuro | `f38a00889f2c32cce78516b3d67fba8f08f6e5a8` |
| 3dsrecomp | `c3f21f94ba50d688025febc8974ff348d471b587` |
| MoltenVK | `1.4.2`，下载包 SHA256 在构建脚本中校验 |
| LLVM-MinGW（Windows 游戏框架） | `20261006` UCRT x86_64 包 |
| Noto Sans JP | Google Fonts `66a36c8c94b1a5d992ee4e7f392fccfe4945767c` |
| fontTools | `4.60.1` |

`source/ios-host/runtime.patch` 只修改通用兼容运行库：移动端服务、图形、声音、共享字体接口及 Metal/Vulkan 适配；不含游戏程序或资源。

## Actions

Fork 本仓库，在 Actions 选择 **Build content-free iOS shell → Run workflow**。流程只接受通用源码，没有游戏路径参数、文件上传步骤或完整游戏包输出。

成功 artifact 包含：

- `output/RhythmHeaven3DS-shell.ipa`
- `output/host_manifest.json`
- `output/shell-audit.json`
- `output-dependencies.txt`

CI 使用固定的 Xcode 路径和 Rust 版本，检查依赖树不含 CPU shader JIT，并对最终空壳使用严格成员白名单检查。CI 的成功表示空壳通过构建和资源检查，不代表每款设备／关卡得到验证。

## 在 Mac 本地编译空壳

安装 Git、Python 3.11+、rustup 和 Xcode 26.6 后，在本仓库根目录执行：

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
rustup toolchain install 1.99.1 --profile minimal --target aarch64-apple-ios
python3 tools/bootstrap.py
cargo tree --manifest-path source/mobile-bridge/Cargo.toml --target aarch64-apple-ios
python3 source/ios-host/build_host.py
python3 tools/audit_shell.py output/RhythmHeaven3DS-shell.ipa
```

空壳生成于 `output/`。通用空壳构建不读取游戏。完整包的 Windows 流程见 [本机打包指南](NO_XCODE.zh-CN.md)。

## 打包边界

公开内容仅为适配源码、说明、构建脚本、第三方许可及空壳。请保持生成的游戏代码、完整 IPA 和存档仅在本机。公开发布前，先审阅 `git diff --cached --stat` 和 `python tools/audit_public.py` 的结果。
