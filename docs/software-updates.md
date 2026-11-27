# 发布 DualDock 更新

从 2.8.0 起，“支持 → 关于 DualDock → 检查更新”启动 Sparkle 的手动检查。用户确认后，Sparkle 下载更新并验证签名，安装到当前应用的位置，再重新启动。2.7.0 及以前的版本需先手动安装一次带更新器的版本。

## 发布者设置

正式应用的 `Resources/Info.plist` 保存了更新公钥和固定 HTTPS 更新清单地址。私钥由发布 Mac 的钥匙串保管，Sparkle 账户名为 `DualDock`。现有正式密钥应持续复用。更换发布 Mac 时应先按 Sparkle 文档安全迁移同一密钥。钥匙串和私钥备份由维护者保管，请勿将私钥写入仓库、日志或聊天。[Sparkle 密钥管理](https://sparkle-project.org/documentation/)

Sparkle 的更新签名由维护者生成，无需付费的 Apple 开发者账户。macOS 首次启动的验证流程仍见 DMG 内的安装指南。应用的更新公钥用于验证清单和下载文件。[Sparkle 发布文档](https://sparkle-project.org/documentation/publishing/)

## 发布步骤

1. 在 `Resources/Info.plist` 更新版本号与单调递增的构建号，准备对应的中英文发布说明 `docs/release-notes/v版本号.md`。
2. 使用 `bash script/package_dmg.sh` 构建最终 DMG。脚本核对固定版本的 Sparkle，嵌入框架和安装辅助程序，检查包签名与 DMG 指南。之后如重建 DMG，需重新进行下列签名步骤。
3. 运行 `bash script/make_appcast.sh`。Sparkle 使用钥匙串中的正式密钥，为最终 DMG 及更新清单签名。脚本以应用内公钥验证签名、文件长度、版本、最低系统要求和下载地址。通过验证的候选清单是 `dist/appcast.xml`。
4. 创建正式 Git 标签，上传该标签对应的 DMG 与 SHA-256 到 GitHub Release，核对远程文件的 SHA-256，然后发布。发布同一版本后不要替换其 DMG。
5. 确认正式下载链接可访问后，将验证过的 `dist/appcast.xml` 原样发布到默认分支的 `updates/appcast.xml`。通过下列方式核对用户实际收到的清单，再从“关于 DualDock”检查更新。

```sh
curl --fail --location https://raw.githubusercontent.com/autumncry/DualDock/main/updates/appcast.xml -o /tmp/dualdock-public-appcast.xml
cmp /tmp/dualdock-public-appcast.xml dist/appcast.xml
```

若上传中断，先核对已发布附件并从中断处继续。保留之前有效的在线清单，直至新附件可用。清单签名覆盖具体字节，手工修改版本说明、链接或排版后需重新生成签名。


## 上一版安装验收

在发布前，以已校验签名的上一版应用为来源，对本次正式构建运行：

```sh
python3 script/check_sparkle_roundtrip.py --from-app "/path/to/previous/DualDock.app" --to-app dist/release/DualDock.app
```

脚本核对正式签名要求、更新地址、公钥及递增构建号。它把两个应用复制到临时目录，用独立测试标识和临时更新密钥验证 Sparkle 的实际安装流程，再逐字节比对安装后的程序。单独运行 `python3 script/check_sparkle_roundtrip.py` 可验证正确签名、清单篡改和 DMG 签名错误三条路径。发布包自身的签名和校验值由 `script/check_signed_update.sh` 验证。
