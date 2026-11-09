# DualDock

供个人使用的 macOS 多屏 Dock。首次运行导入系统 Dock 的固定应用，之后独立保存分组与排列。最低部署目标为 macOS 14；本次构建与验证环境为 macOS 27.0.1 / Apple M5，发布包为 Apple Silicon 版本。

## 打开

从 [GitHub Release](https://github.com/autumncry/DualDock/releases/tag/v1.3.0) 下载 `DualDock-1.3.0-arm64.dmg`，打开后把 `DualDock.app` 拖到 `Applications`。仓库及发布包公开提供。

也可以打开本地构建的 `dist/DualDock.app`。首次启动显示设置；右键 Dock 空白处或点击菜单栏的双矩形图标可以再次打开设置。退出入口在菜单栏中。

在“权限”页授予屏幕录制与辅助功能。前者用于窗口缩略图，后者用于切换指定窗口。修改权限后如未生效，退出并重新打开应用。窗口截图仅在内存中缓存，不写入磁盘或上传。

## 四项功能

- 从 Finder 拖入应用，或用“添加应用”。拖到其他图标边缘调整顺序；在图标中央停留约 0.6 秒后松开可以建组。点击组图标横向展开，可组内重排、拖回主栏，右键重命名或拆组。
- 悬停运行中的应用显示窗口缩略图，点击切换窗口；缩略图右上角的 × 用于关闭对应窗口。未保存内容由原应用提示确认，DualDock 不会代选保存或丢弃。点击关闭会收起预览，再次悬停读取最新窗口列表。无法捕获有效截图的窗口不显示预览。
- 普通模式显示固定应用、应用组及未固定运行应用。仅运行模式将全部普通运行应用平铺，包括最小化、隐藏和其他桌面的应用。切换模式保留原布局。
- 每个扩展显示器分别有一条 Dock，共享同一配置。镜像显示器由系统复制对应画面。某屏进入全屏应用时隐藏该屏的栏，其他屏继续使用。

“Dock 高度”和“Dock 宽度”分别使用连续滑块，两项独立；高度同步缩放图标，宽度保持用户选择，不随间距或应用数量变化。所有屏幕共用同一套有效尺寸：宽度上限取最窄屏幕的完整有效宽度，高度上限取最矮屏幕有效高度的 12%（指底板高度）。显示尺寸以 macOS 缩放后的逻辑点计算。接入较小屏幕时只限制实际显示尺寸，保留原始选择，断开后可恢复。升级时保留已有栏宽并备份配置。

“图标间距”只改变内部疏密；内容超出栏内可见宽度时可以手动横向滚动，不显示滑块。鼠标附近的图标平滑联动放大，中心最大、两侧逐级减小，图标后不叠加悬停底色；Dock 底板尺寸和位置保持不变，可在设置中关闭放大或调整幅度。Dock 内不显示设置和模式切换按钮，显示模式统一在设置的“显示内容”中切换。应用组采用独立文件夹轮廓，右键菜单从图标右上方展开。“重新导入系统 Dock”会补入尚未固定的应用，保留已有分组和顺序。

## 消息角标

在设置中开启或关闭“显示消息数量角标”。单个应用显示系统实际提供的标签，应用组有未读提醒时显示红色叹号。后台每两秒更新，关闭会清除显示。角标读取只涉及状态标签，不读取或上传通知正文。部分应用或系统版本可能不提供可用标签。

## 系统 Dock

“隐藏系统 Dock”默认关闭。开启前保存原始偏好，正常退出时恢复；异常退出后再次启动会先恢复，再按已保存的开关状态应用设置。菜单栏提供“恢复系统 Dock”。恢复时只还原仍与 DualDock 所写值相符的键，保留用户随后修改的设置。

配置与恢复记录位于 `~/Library/Application Support/DualDock/`。配置异常时保留原文件并提示错误。

## 构建与验证

需要 Xcode 或合适的 Swift/macOS SDK。无第三方包依赖。

```sh
./script/build_and_run.sh              # 编译、打包、本地签名并启动
./script/build_and_run.sh --build-only # 只构建 .app
./script/build_and_run.sh --verify     # 构建、启动并检查进程
./script/package_dmg.sh               # release 构建，生成 DMG 与 SHA-256 校验文件
swift test                            # 分组、排序及模式数据不变性测试
./script/check_system_dock.sh          # 内存偏好注入的恢复故障测试
./script/check_badges.sh               # 角标读取、关闭与异步隔离检查
./script/check_dock_views.sh           # 隐藏 AppKit 视图的滚动与预览按钮检查
```

脚本支持 `--logs`、`--telemetry` 与 `--debug`。Codex Run 按钮也使用该脚本。重新构建会先请求已运行的 DualDock 正常退出，以完成系统 Dock 恢复。

本地测试可以用 `--config-dir <独立目录>` 指定隔离配置，`--diagnostics <JSON路径>` 输出屏幕面板状态供验证；这些参数通过 `.app` 启动，例如 `open -n dist/DualDock.app --args --config-dir /private/tmp/dualdock-test --diagnostics /private/tmp/dualdock-test.json`。

## 平台边界

窗口身份匹配及全屏空间查询使用可选动态加载的 macOS 私有接口，接口不可用时退回公开辅助功能 API。系统升级后可能需要适配。其他桌面、最小化或受保护窗口的截图和切换能力受目标应用及 macOS 限制。

应用为本机个人使用进行 ad-hoc 签名，未进行 Apple 公证。最新验证记录见 `docs/validation.md`。

分析依据与设计见 `docs/superpowers/specs/2026-11-09-dualdock-design.md`；原始 REA Evidence 属于本地研究资料，保存在相邻 `../research/Dockish-1.2.8/`，未随源码仓库或安装包发布。

## 协议

采用 [MIT License](LICENSE)，Copyright (c) 2026 Ronny Cao。源码仓库已公开。
