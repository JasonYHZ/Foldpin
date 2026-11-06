# 通用预览包与开源发行

当前方案：GPL-3.0-only 源码 + GitHub Releases 通用预览包；后续再接自建 Homebrew tap。此文描述已准备的本地流程，不表示已经公开发布。

2026-11-06 更新：已从干净提交 `dd3c3ed` 重建并发布 [v0.1.0-preview.1](https://github.com/JasonYHZ/Foldpin/releases/tag/v0.1.0-preview.1)。5 个附件的 GitHub SHA-256 与本地一致；标签指向同一提交。用户决定先保持仓库私有，处理资料后再公开。根目录 `Casks/foldpin.rb` 已准备自建 tap，详见 [Homebrew](homebrew.md) 与[公开资料待办](public-repository-preparation.md)。

## 生成

在仓库根目录执行：

```sh
python3 scripts/package-release.py --version 0.1.0 --build 1 --label 0.1.0-preview.1
```

需要 Xcode、Python 3、macOS 自带的 ditto / codesign / hdiutil。脚本固定 arm64 + x86_64、Release、ad-hoc 签名，关闭基础调试权限注入；不使用开发者证书。保持 Bundle ID，不改项目内的开发签名配置。发行版本作为构建参数传给 Xcode，不改工程版本。

输出目录 dist/Foldpin-0.1.0-preview.1/：

- Foldpin-…-universal.zip 与 .dmg：同一款通用应用及许可、安装说明。
- Foldpin-…-source.zip：构建实际使用的源码快照，包含脚本、测试、内置第三方资源及许可。
- build-info.json：基准 Git 提交、工作区是否有改动、Xcode 版本、两个架构、最低系统与源码文件哈希。
- SHA256SUMS：以上产物的 SHA-256。
- build.log：本地诊断日志，可能含本机路径，不应直接上传。

源码快照会包含工作区未提交的应用文件，不能用 HEAD 的源码压缩包替换。脚本只冻结 macOS/、scripts/、根许可与使用/贡献说明和本发行说明，排除构建缓存及 Git 用户状态；不收集个人环境文件、研究、聊天档案、营销 ZIP。输出目录存在时拒绝覆盖。

脚本在临时快照上构建，检查双架构、签名、无调试权限、许可和八语言的编译资源，成功后才交付目录。它不运行应用，不验证真实录音、窗口操作、Intel 实机、Gatekeeper 或跨版本升级。

## 发布前

1. 在独立用户环境验收真实浏览器下载、首次放行、重启保留、导入导出、目录授权及升级；验证最低系统和 Intel 实机。
2. 复核应用图标等正式资源的授权，以及准备公开的历史资料、截图、压缩包和 Git 历史。已有正则密钥检查不等同完整隐私审计。
3. 将准备发行的源码完整提交并打标签，在干净快照上重新生成同版本产物；不直接发布工作区预览产物作为稳定版。
4. 同时上传安装包、对应源码 ZIP、build-info.json 与 SHA256SUMS，保留源码与二进制的一一对应。不要上传 build.log。

## 签名与 Homebrew

ad-hoc 签名可以用于本地校验代码完整性，但不是 Developer ID 签名或 Apple 公证。用户系统可能阻止首次打开。安装说明不要求关闭 Gatekeeper 或移除整个系统的安全设置。

自建 Homebrew tap 配置已添加：ZIP 内应用位于根目录 Foldpin.app，两种芯片共用一个 URL 与 SHA。最低系统约束保持 macOS 26.5，不能写成所有 macOS 26 均兼容。当前仓库保持私有，未向公众提供 tap，也未向官方 homebrew/cask 提交收录 PR。

## 仓库整理

根 README 面向用户，旧版内容保存在 project-history.md；根目录的设计 QA 归入本目录，output/imagegen/ 与 tmp/imagegen/ 的现有素材归入 docs/design/generated/。不删除研究原件，不重写 Git 历史，不把归档搬动当作隐私清理。
