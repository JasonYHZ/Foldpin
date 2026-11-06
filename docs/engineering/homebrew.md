# Homebrew 分发准备

Foldpin 是图形应用，本轮准备 Cask，配置位于根目录 `Casks/foldpin.rb`。它引用0.1.0 常规 Release 的通用 ZIP，两个架构共用同一个下载地址和 SHA-256；最低系统精确限制为 macOS 26.5。

Homebrew 7 不再接受数字形式的最低系统比较，因此使用 `depends_on macos: :tahoe` 声明主版本，再在安装前检查 26.5 的小版本下限；检查失败不会安装应用。

## 当前选择

先使用项目自己的 tap，再考虑向官方 `homebrew/cask` 提交 PR。自建 tap 无需官方审批；它也不代表官方收录或安全背书。当前应用采用 ad-hoc 签名且未公证，官方要求应用通过 Gatekeeper 检查，所以本轮不向官方仓库提交一个已知不符合该项要求的 PR。

参考：[官方 Cask 收录要求](https://docs.brew.sh/Acceptable-Casks)、[创建与维护 tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)。

## 发布后使用

先确认仓库与 Release 已公开，下载地址无需登录即可访问。当前仓库名不是 `homebrew-*`，因此添加 tap 时必须明确给出 Git URL：

```sh
brew tap jasonyhz/foldpin https://github.com/JasonYHZ/Foldpin.git
brew install --cask jasonyhz/foldpin/foldpin
```

用户应先检查并信任自己要安装的第三方 tap。Homebrew 安装不会赋予 Apple 公证，不能保证首次启动通过 Gatekeeper。本 Cask 没有移除隔离属性或关闭系统安全保护的脚本，也没有删除用户纸片库的卸载步骤。

上面的命令是分发配置，不能在仓库仍为私有或 Release 附件尚未发布时宣称已经可供公众安装。不得为了测试覆盖开发者正在使用的 Foldpin.app 或操作真实纸片库。

## 后续维护

1. 新版本从固定提交构建，先发布对应 Release 和源码。
2. 更新 Cask 的 version 与真实 ZIP 的 SHA-256，检查最低系统与包内应用路径。
3. 检查下载、Cask 解析及实际安装/卸载行为；使用独立测试用户，保留真实数据。
4. 有 Developer ID 签名、公证及 Gatekeeper 验收后，再复核官方完整收录要求、项目关注度等条件并提交 PR。

当前仅准备一个常规发行渠道，没有自动更新器、后台更新服务或自动清除数据。

## 本轮验证

Homebrew 7.0.12 的实际 Cask DSL 解析通过（从内容加载，仅解析，不安装）。核对 version、ZIP URL、SHA-256、应用路径与安装前步骤；当前 Cask SHA 已更新为隐私重建后的本地 ZIP；远程附件替换并复核前，不宣称已与当前 GitHub 下载一致。系统版本检查分别覆盖 25.9、26.0、26.4、26.5、26.10、27.0 和空值，均按预期允许或拒绝。未执行安装、卸载、完整 brew audit 或真实升级验收，未改动现有 Foldpin 应用及纸片库。
