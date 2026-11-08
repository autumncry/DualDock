# DualDock

供个人使用的 macOS 多屏 Dock。首次运行导入系统 Dock 的固定应用，之后独立保存分组与排列。支持 macOS 14 及以上；本次交付构建为 Apple Silicon 版本。

## 打开

打开 `dist/DualDock.app`。首次启动显示设置，菜单栏的双矩形图标可以再次打开设置或退出。

在“权限”页授予屏幕录制与辅助功能。前者用于窗口缩略图，后者用于切换指定窗口。修改权限后如未生效，退出并重新打开应用。窗口截图仅在内存中缓存，不写入磁盘或上传。

## 四项功能

- 从 Finder 拖入应用，或用“添加应用”。拖到其他图标边缘调整顺序；在图标中央停留约 0.6 秒后松开可以建组。点击组图标横向展开，可组内重排、拖回主栏，右键重命名或拆组。
- 悬停运行中的应用显示窗口缩略图，点击切换窗口。无法捕获的窗口显示标题或应用图标。
- 普通模式显示固定应用、应用组及未固定运行应用。仅运行模式将全部普通运行应用平铺，包括最小化、隐藏和其他桌面的应用。切换模式保留原布局。
- 每个扩展显示器分别有一条 Dock，共享同一配置。镜像显示器由系统复制对应画面。某屏进入全屏应用时隐藏该屏的栏，其他屏继续使用。

图标在窄屏上会自动缩小，超长的栏和应用组可以横向滚动。“重新导入系统 Dock”会补入尚未固定的应用，保留已有分组和顺序。

## 系统 Dock

“隐藏系统 Dock”默认关闭。开启前保存原始偏好，正常退出时恢复；异常退出后再次启动会先恢复，再按已保存的开关状态应用设置。菜单栏提供“恢复系统 Dock”。恢复时只还原仍与 DualDock 所写值相符的键，保留用户随后修改的设置。

配置与恢复记录位于 `~/Library/Application Support/DualDock/`。配置异常时保留原文件并提示错误。

## 构建与验证

需要 Xcode 或合适的 Swift/macOS SDK。无第三方包依赖。

```sh
./script/build_and_run.sh              # 编译、打包、本地签名并启动
./script/build_and_run.sh --build-only # 只构建 .app
./script/build_and_run.sh --verify     # 构建、启动并检查进程
swift test                            # 分组、排序及模式数据不变性测试
./script/check_system_dock.sh          # 内存偏好注入的恢复故障测试
```

脚本支持 `--logs`、`--telemetry` 与 `--debug`。Codex Run 按钮也使用该脚本。重新构建会先请求已运行的 DualDock 正常退出，以完成系统 Dock 恢复。

本地测试可以用 `--config-dir <独立目录>` 指定隔离配置，`--diagnostics <JSON路径>` 输出屏幕面板状态供验证；这些参数通过 `.app` 启动，例如 `open -n dist/DualDock.app --args --config-dir /private/tmp/dualdock-test --diagnostics /private/tmp/dualdock-test.json`。

## 平台边界

窗口身份匹配及全屏空间查询使用可选动态加载的 macOS 私有接口，接口不可用时退回公开辅助功能 API。系统升级后可能需要适配。其他桌面、最小化或受保护窗口的截图和切换能力受目标应用及 macOS 限制。

应用为本机个人使用进行 ad-hoc 签名，未进行 Apple 公证。最新验证记录见 `docs/validation.md`。

分析依据与设计见 `docs/superpowers/specs/2026-11-09-dualdock-design.md`；原始 REA Evidence 位于相邻 `../research/Dockish-1.2.8/`。
