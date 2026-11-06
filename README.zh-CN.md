# Foldpin

**随手记，眼前贴，一键收。**

[English](README.md) · 简体中文

Foldpin 是一款原生 macOS 桌面随手记工具，使用 SwiftUI、AppKit 和 NSTextView 构建。每张纸片都是独立窗口，让待办、代码片段和参考资料留在工作旁边。

## 功能

- **独立多纸片：** 置顶、折叠、排列、收纳，在收纳架找回纸片，并恢复最近删除的内容。
- **原生区块编辑：** 标题、列表、待办、表格、代码、图片、链接卡片及 Markdown 粘贴。
- **本地媒体与附件：** 录音、音视频和文件附件，支持 Markdown / HTML 导出。
- **外观与快捷键：** 纸感和液态玻璃、明暗主题、纸片颜色、字体及自定义快捷键。
- **八种界面语言：** 英文、简体中文、繁体中文、日语、韩语、德语、法语和西班牙语。
- **可选本机 MCP：** 默认关闭，启用后需客户端授权和内容访问控制，见 [MCP 说明](docs/engineering/mcp-support.md)。

笔记及附件保存在本机。链接预览会请求目标网站；启用 MCP 后，获授权的外部客户端可以访问你允许的内容，其后续处理由客户端决定。当前没有云同步、内置 AI 整理或语音转写。

## 下载与安装

最低 **macOS 26.5**。一个通用包同时支持 **Apple Silicon（arm64）和 Intel（x86_64）**；Intel Mac 也需要满足最低系统要求。

[下载 Foldpin 0.1.0](https://github.com/JasonYHZ/Foldpin/releases/tag/v0.1.0)

1. 在 Release 附件中下载 `Foldpin-0.1.0-universal.dmg`。
2. 打开 DMG，将 **Foldpin.app** 拖到 **Applications（应用程序）**。
3. 启动 Foldpin。升级已有版本前，请先备份完整纸片库。

应用采用 **ad-hoc 签名，未经 Apple 公证**，首次打开可能被系统阻止。确认下载来源后，可在「系统设置 → 隐私与安全性」查看「仍要打开」，具体取决于系统策略。无需全局关闭系统安全保护。

| 文件 | 用途 |
| --- | --- |
| `Foldpin-0.1.0-universal.dmg` | 推荐安装包，两种芯片通用 |
| `Foldpin-0.1.0-universal.zip` | 同一应用的 ZIP 版本 |
| `Foldpin-0.1.0-source.zip` | 本安装包实际使用的源码快照 |
| `SHA256SUMS` | 下载校验清单 |
| `build-info.json` | 源码提交、工具链与文件哈希 |

发行检查涵盖自动测试、双架构构建、签名完整性和编译后翻译。Intel 实机、最低系统实机、全新用户、真实下载后的 Gatekeeper 及升级流程尚未完成手动验收，详见[版本验证记录](docs/engineering/release-0.1.0.md)。

## 开始使用

按 **⌘N** 新建纸片，用置顶按钮留在眼前，再通过收纳架收起和找回。输入 `/` 打开区块菜单，按 **⌘K** 打开纸片操作。在「设置 → 通用 → 语言」切换界面语言。

关闭空白纸片会移入最近删除；关闭有内容的纸片会收纳。导出适合分享内容，不能替代整个纸片库的备份。

## 从源码构建

使用支持当前最低系统目标的 Xcode，打开 `macOS/Foldpin.xcodeproj`，选择 **Foldpin / My Mac** 后运行，无需另建 `.xcworkspace`。

在仓库根目录生成通用发行包：

```sh
python3 scripts/package-release.py --version 0.1.0 --build 2 --label 0.1.0
```

脚本冻结当前源码，为两种架构构建 Release，生成 DMG、ZIP、对应源码和校验清单，输出到被 Git 忽略的 `dist/`。脚本不会提交、打标签或上传；发布时应从干净提交构建。

开发、测试和数据目录说明见[原生工程说明](macOS/README.md)，打包细节见[发行说明](docs/engineering/distribution.md)。

## Homebrew

通过项目自建 tap 安装：

```sh
brew tap jasonyhz/foldpin https://github.com/JasonYHZ/Foldpin.git
brew install --cask jasonyhz/foldpin/foldpin
```

仓库名是 Foldpin，而非 homebrew-foldpin，因此添加 tap 时需要完整 Git URL。新版 Homebrew 的完整名称安装命令仅信任此 Cask；请先查看配置。应用仍采用 ad-hoc 签名且未公证，首次启动可能需要在系统「隐私与安全性」中批准。

当前通过自建 tap 分发，尚未被官方 Homebrew Cask 收录，见 [Homebrew 分发说明](docs/engineering/homebrew.md)。

## 参与与许可

欢迎通过 [GitHub Issues](https://github.com/JasonYHZ/Foldpin/issues) 报告问题，附上系统版本、芯片类型、Foldpin 版本和复现步骤。请移除私人笔记、凭据及个人路径，见[贡献说明](CONTRIBUTING.md)。

Foldpin 原创应用代码和构建脚本采用 **GPL-3.0-only**，按许可提供且不作担保，完整条款见 [LICENSE](LICENSE)。第三方代码、主题和 Unicode 数据保留各自条款，见[第三方声明](macOS/Foldpin/ThirdPartyNotices.txt)。私人研究、设计参考和营销档案不纳入公开源码。

## 仓库导航

| 路径 | 内容 |
| --- | --- |
| [macOS](macOS/README.md) | 原生应用、资源与测试 |
| [scripts](scripts) | 打包、校验及资源生成脚本 |
| [docs/engineering](docs/engineering) | 实现说明与验证记录 |

多数工程文档目前为中文。复用旧克隆前，请阅读仓库清理记录，避免重新引入已移除的资料。
