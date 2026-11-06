# Homebrew 分发

Foldpin 是图形应用，通过项目自建 tap 提供 Cask，配置位于根目录 `Casks/foldpin.rb`。它引用0.1.0 常规 Release 的通用 ZIP，两个架构共用同一个下载地址和 SHA-256；最低系统精确限制为 macOS 26.5。

Homebrew 7 不再接受数字形式的最低系统比较，因此使用 `depends_on macos: :tahoe` 声明主版本，再在安装前检查 26.5 的小版本下限；检查失败不会安装应用。

## 当前选择

先使用项目自己的 tap，再考虑向官方 `homebrew/cask` 提交 PR。自建 tap 无需官方审批；它也不代表官方收录或安全背书。当前应用采用 ad-hoc 签名且未公证，官方要求应用通过 Gatekeeper 检查，所以本轮不向官方仓库提交一个已知不符合该项要求的 PR。

参考：[官方 Cask 收录要求](https://docs.brew.sh/Acceptable-Casks)、[创建与维护 tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)。

## 安装

公开仓库的 v0.1.0 已发布为 Latest，公开下载及 Homebrew 安装验证通过。添加 tap 时明确给出 Git URL：

```sh
brew tap jasonyhz/foldpin https://github.com/JasonYHZ/Foldpin.git
brew install --cask jasonyhz/foldpin/foldpin
```

这是项目自建 tap，不代表官方收录。Homebrew 安装不会赋予 Apple 公证；首次启动可能需要在系统隐私与安全设置中批准。本 Cask 不移除隔离属性、不关闭系统安全保护，卸载也不删除纸片库。

## 后续维护

1. 新版本从固定提交构建，先发布对应 Release 和源码。
2. 更新 Cask 的 version 与真实 ZIP 的 SHA-256，检查最低系统与包内应用路径。
3. 检查下载、Cask 解析及实际安装/卸载行为；使用独立测试用户，保留真实数据。
4. 有 Developer ID 签名、公证及 Gatekeeper 验收后，再复核官方完整收录要求、项目关注度等条件并提交 PR。

当前仅准备一个常规发行渠道，没有自动更新器、后台更新服务或自动清除数据。

## 本轮验证

Homebrew 7.0.12 的实际 Cask DSL 解析通过（从内容加载，仅解析，不安装）。核对 version、ZIP URL、SHA-256、应用路径与安装前步骤；当前 Cask SHA 已更新为隐私重建后的 ZIP，并与用户重新上传的 GitHub 正式版附件摘要核对一致。系统版本检查分别覆盖 25.9、26.0、26.4、26.5、26.10、27.0 和空值，均按预期允许或拒绝。公开 Release 发布后，Homebrew 实际下载并校验 ZIP、安装到临时应用目录，随后卸载成功。安装后的应用为 0.1.0 / build 2，包含 arm64 和 x86_64，严格签名校验通过，隔离属性保留。未启动应用或绕过 Gatekeeper，未执行完整 brew audit、独立新用户首次启动或真实升级验收；未操作现有 Foldpin 应用及纸片库。
