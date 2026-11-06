# Foldpin

**Floating sticky notes for Mac · 随手记，眼前贴，一键收。**

Foldpin 是一款原生 macOS 桌面随手记工具。每张纸片都是独立窗口：记录想法、置顶参照、折叠或收纳，再按需找回。

当前处于**开源预览准备阶段**，尚未发布正式版本。已创建 [0.1.0 Preview 1](https://github.com/JasonYHZ/Foldpin/releases/tag/v0.1.0-preview.1)，仓库按维护者决定暂时保持私有，需有访问权限才能下载。实现状态和待验收项见[发行说明](docs/engineering/distribution.md)。

## 已有功能

- 多张独立纸片，置顶、折叠、排列、收纳、搜索与最近删除。
- 原生区块编辑：标题、列表、待办、表格、代码、图片、链接卡片及 Markdown 粘贴。
- 本地录音、音视频与文件附件；Markdown / HTML 导出。
- 纸感与液态玻璃外观，明暗主题、颜色、字体和自定义快捷键。
- 简体中文、繁体中文、英文、日语、韩语、德语、法语与西班牙语。
- 可选的本机 MCP 服务，默认关闭，启用后需授权客户端。见[MCP 说明](docs/engineering/mcp-support.md)。

笔记及附件保存在本机。链接预览会请求目标网站；启用 MCP 后，获授权的外部客户端可以读取授权内容，其后续处理由该客户端决定。尚无云同步、内置 AI 整理或语音转写。

## 系统与安装

最低 **macOS 26.5**。通用构建同时包含 **Apple Silicon（arm64）和 Intel（x86_64）**，两种芯片使用同一个安装包；Intel Mac 也需要满足最低系统要求。

预览包采用 ad-hoc 签名，**未经 Apple 公证**，下载后可能被 Gatekeeper 阻止。确认来源后可尝试在「系统设置 → 隐私与安全性」使用「仍要打开」；具体提示取决于系统策略。无需全局关闭系统安全保护。尚未完成真实下载、全新用户及 Intel 实机验收。

预览安装包、对应源码和校验清单已上传至 Release。自建 tap 的 Cask 配置已准备好，仓库与附件公开后才能供公众安装；命令和当前限制见 [Homebrew 分发说明](docs/engineering/homebrew.md)。当前未被官方 homebrew/cask 收录。

## 从源码构建

使用支持 macOS 26.5 SDK 的 Xcode，打开 `macOS/Foldpin.xcodeproj`，选择 Foldpin / My Mac 后运行。现有工程使用 `.xcodeproj`，无需另外创建 `.xcworkspace`。

在仓库根目录生成一个带对应源码和校验值的通用预览包：

```sh
python3 scripts/package-release.py --version 0.1.0 --build 1 --label 0.1.0-preview.1
```

脚本从当前工作目录冻结源码（包含未提交的新文件），以 Release 构建两个架构，生成 ZIP、DMG、对应源码 ZIP 和 SHA-256 清单。输出位于 `dist/`，不纳入 Git。它不会提交、打标签或上传。

开发、测试与数据目录说明见[原生工程说明](macOS/README.md)。升级前建议备份整个纸片库；导出适合交换内容，不能代替完整库备份。

## 参与开发与许可

欢迎通过 [GitHub Issues](https://github.com/JasonYHZ/Foldpin/issues) 报告问题，请附系统版本、芯片类型、版本号及复现步骤，避免提交私人笔记。见[贡献说明](CONTRIBUTING.md)。

Foldpin 原创应用代码和构建脚本采用 **GPL-3.0-only**，完整条款见 [LICENSE](LICENSE)，按许可提供且不作担保。第三方代码、主题和 Unicode 数据保留各自许可，见[第三方声明](macOS/Foldpin/ThirdPartyNotices.txt)。研究引用、参考截图和外部设计资料不因进入本仓库而取得额外授权。

## 仓库导航

| 路径 | 内容 |
| --- | --- |
| [macOS](macOS/README.md) | 原生应用、资源与测试 |
| [scripts](scripts) | 构建、校验和资源生成脚本 |
| [docs/engineering](docs/engineering) | 实现说明、验证边界与历史记录 |
| [docs/design](docs/design/ui-v0.1/README.md) | 设计资料，生成产物集中在 docs/design/generated/ |
| [PRD.md](PRD.md) | 产品目标与分期，包含尚未实现的规划 |
| [开发历史](docs/engineering/project-history.md) | 原 README 中按日期保留的开发记录 |

公开整个仓库前仍需复核历史研究资料、截图与压缩包的隐私及授权范围；源码发行包仅包含应用构建所需文件和相关说明，不包含研究与营销档案。目录整理不会移除 Git 历史中的资料。
