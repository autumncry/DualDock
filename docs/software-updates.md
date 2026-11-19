# DualDock 应用内更新可行性

**建议采用用户点击后检查、确认后安装的方式。** 设置入口可放在“支持 → 关于 DualDock”的版本号旁。2.7.0 仍通过 GitHub Releases 分发 DMG。

Netcatty 1.1.90 的手动检查先向 GitHub 查询最新版本并比较版本号。发现更新后，支持的平台会进入 Electron 更新器的下载流程，设置页显示进度，用户确认后重启安装。[检查逻辑](https://github.com/binaricat/Netcatty/blob/8d15a29bc69ff48c2331298c2015df9570cfcbe9/application/state/useUpdateCheck.ts#L431-L466) · [macOS 安装动作](https://github.com/binaricat/Netcatty/blob/8d15a29bc69ff48c2331298c2015df9570cfcbe9/electron/bridges/autoUpdateBridge.cjs#L564-L590)

DualDock 可用 URLSession 查询官方 Releases，比较稳定版本，展示变更和下载入口。要把“下载”延伸到“替换应用并重启”，建议嵌入原生 Sparkle 2，由发布流程生成 HTTPS appcast、为每个最终 DMG 签署 Ed25519 签名，并将对应公钥嵌入应用。现有 DMG 和 SHA-256 可继续提供给手动安装的用户。发布私钥应由维护者保管；同一发行页上的 SHA-256 文件本身无法验证发布者身份。[Sparkle 集成](https://sparkle-project.org/documentation/) · [发布和签名流程](https://sparkle-project.org/documentation/publishing/)

当前采用 ad-hoc 代码签名。Sparkle 更新签名和 Apple Developer ID 签名、公证分别承担更新来源验证和系统分发信任。正式集成时需要修改现有 SwiftPM 打包脚本以嵌入框架和其所需组件，校验嵌套签名、执行权限和符号链接。首次带更新器的版本需手动安装一次。发布前宜用两份真实构建验证升级后启动、配置与分组保留、辅助功能和录屏授权、登录项、下载中断与签名不匹配时的恢复。Apple 关于首次启动的安装说明继续保留。[Sparkle 官方签名建议](https://sparkle-project.org/documentation/)
