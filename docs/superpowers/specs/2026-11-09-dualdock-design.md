# Dockish 1.2.8 分析与 DualDock 设计

日期：2026-11-09。用途：为个人自用的 DualDock 确定四项核心功能的实现。用户已在 2026-11-09 确认首版范围，本文作为已批准的实施规格与分析依据。

## 1. 分析对象与证据范围

- 本地程序 `/Applications/Dockish.app`，版本 1.2.8，Universal Mach-O，本轮分析 arm64。
- 主程序 SHA-256 为 `435bc46159b5335d6d60cf109fc98b32ad503c6d8dfe0545aeb95d95ce75d7cc`。
- REA 使用 Hopper，共保留 38 条 Evidence，见同目录 `evidence-final.json`。反编译结果是静态伪代码，不是 Dockish 原始源代码，也不代表观察到实际执行。
- 本地 Dockish 配置只保留结构投影，见 `config-shape.json`。应用名称、路径、bookmark 内容和其他设置没有复制到投影文件。
- 本轮另以宿主 Swift/AppKit/ScreenCaptureKit 只读探针核对开发环境，结果与 REA 静态证据分开记录。

## 2. 四项功能如何实现

### 2.1 应用集合与分组弹窗

**已观察到的数据结构**：Dockish 配置采用有序 `elements` 数组，每项包含 `type` 与 `payload`。普通应用 payload 含 `id`、`bundleID`、`bookmarkData`。分组 payload 含 `id`、`name`、`apps`、`style`、`iconStyle`，其中 apps 的每个成员又是普通应用引用。分隔线也有自己的条目类型。

因此可以确认，分组属于应用内部的虚拟数据模型，成员通过 bundle ID 和 bookmark 定位。分组操作无需移动 `/Applications` 中的程序。本地样本已有 6 成员和 4 成员的两个组，存储样式为 grid；用户已经明确要求 DualDock 使用横向展开。

**已观察到的呈现路径**：程序有 `FolderPanelController`、`DockBarView.currentLayout`、`onMergeIntoFolder`、`onDropIntoFolder` 等类型或字段。函数 `0x1000f9f10` 读取 Dock 边缘、Dock 屏幕坐标、分组锚点坐标，枚举 NSScreen 并将弹窗约束到锚点所在屏幕范围。

Evidence：`ev_276da8ff0570febc546c74c9e74f5a9c11155a857dfd2ac4982bb46fc13bd5f6`，类型/字段检索 `ev_c3e4db82b47d5939b2162fe578ec5b47ef2a59307c66134861724391d45363da`，以及配置结构投影。

**尚未逐条闭合的内部细节**：Dockish 合并拖拽的停留阈值、完整编辑事务、空组清理算法。DualDock 将根据已确认的交互要求独立实现这些逻辑。

### 2.2 已打开窗口的预览

**已观察到的截图路径**：函数 `0x100172760` 创建 `SCStreamConfiguration` 与 `SCContentFilter`，以 `initWithDesktopIndependentWindow:` 绑定窗口，读取窗口 frame、pointPixelScale，设置缩略图宽高与 `showsCursor=false`，异步调用 `SCScreenshotManager.captureImageWithFilter:configuration:completionHandler:`。

这条路径使用按窗口截图生成缩略图。程序另外存在 `WindowPreviewController`、`WindowPreviewStrip`、预览悬停等待和关闭宽限参数。

Evidence：`ev_2800a80543de8a7ece8a78954e4aa8b2ed8819beb57eb9d3edb527788761c571`。导入表 `ev_8e552f5d775b449c41112fdd726d857c86d414176db37827571aaf1b9d47e0c2` 包含 ScreenCaptureKit 与 Accessibility 相关依赖。

**平台边界与补充证据**：ScreenCaptureKit 窗口 ID 与 Accessibility 窗口对象没有可靠的公开一一映射。REA 导入表存在 `dlopen/dlsym`。常规 arm64 `otool` 反汇编进一步确认，`0x1000d820c` 通过 `dlopen(NULL,1)`、`dlsym(handle,"_AXUIElementGetWindow")` 缓存函数指针；`0x1000d8240` 内的 `0x1000d8890` 实际调用该指针，传入 AX 元素及窗口 ID 输出槽，并检查返回码。因此可以确认 Dockish 使用该私有接口查询窗口身份。这部分属于常规工具补充证据，详见 `otool-supplement.md`，不冒充 REA Evidence。

Dockish 内置文案指出其他 Spaces 的窗口可能缺失于预览与右键菜单。宿主探针成功对一个屏外普通窗口生成 320×270 截图，约 221 ms，图像只在内存中使用，没有保存或展示。这只证明当前系统中该类窗口可捕获，不能推广到全部最小化、其他 Spaces 或受保护内容。

### 2.3 普通模式与仅运行应用模式

**已观察到的数据来源和开关**：配置包含 `showPinnedApps`、`showRunningApps`。二进制含 `runningOnly`、`toggleRunningOnly` 及“运行模式隐藏固定条目”的界面文案。

函数 `0x1000d393c` 调用 `NSWorkspace.runningApplications`，过滤 `activationPolicy == .regular`、自身 PID、`com.apple.dock` 与已终止进程。该函数还维护 AXObserver，说明它参与运行应用/窗口监测，尚不能将它直接等同于生成最终 Dock UI 列表的函数。

Evidence：`ev_cde1057cb2e4cc0356eacdf88ee074b98c70b95d041dd544b218893850e0f632`、`ev_e302dc3b714d9c1c55b51b508f64de322eff3698dcae4a2175035c2c438d6860`。

**DualDock 的已确认语义**：普通模式保存固定应用、分组与顺序。仅运行模式将所有正在运行的普通应用平铺，包括最小化、隐藏和其他桌面的应用，暂时隐藏固定条目和分组。切回普通模式恢复原布局。切模式只切换派生列表，不删除或重建持久化分组。

### 2.4 每个扩展/镜像屏的 Dock

**已观察到的屏幕处理**：函数 `0x10018f3e4` 枚举 NSScreen，读取屏幕尺寸和 deviceDescription 的显示 ID，经 `CGDisplayCreateUUIDFromDisplayID`、`CFUUIDCreateString` 获得稳定身份并生成屏幕/布局记录。`0x100194b48` 遍历已有控制器窗口的 screen，进行屏幕区域相交判断，并检查 `CGDisplayMirrorsDisplay`，跳过镜像从属屏的重复处理。程序包含 `DockScreenController`、`DockWindowManager` 和 `DockPanel` 子类。

Evidence：`ev_240c61cc27914057574ff2ae7b2e110867e2612aac53de3073fd78765f9002c5`、`ev_811cbd74b19c9f3240fda03613ed35bc369c4044afa8f33c0a8bd23a47c90480`、`ev_3f8c5976941f134344370cfaa25a669f74b51a65d35ec5e5e1d268bd282b09a1`。

**面板创建的补充证据**：常规 arm64 `otool` 反汇编确认，调用者 `0x10018808c` 分配 DockScreenController 并调用初始化函数 `0x100184050`。该函数分配 DockPanel，并通过 NSPanel 的初始化方法传入 `styleMask=0x80`（nonactivatingPanel）。之后配置透明背景、不抢主窗口/键盘焦点、`collectionBehavior=0x151`（canJoinAllSpaces、stationary、ignoresCycle、fullScreenAuxiliary）、不随应用失活隐藏、接收鼠标移动事件。管理函数还逐项遍历由 `0x100190af0` 返回的非镜像从属屏数组，按屏幕标识复用或新建控制器。这闭合了按选中逻辑显示器创建独立 Dock 面板的路径及关键窗口属性。详见常规工具补充记录 `otool-supplement.md`。

**DualDock 拟采用的明确实现**：每个可绘制逻辑 NSScreen 对应一张不抢焦点的 NSPanel，所有面板绑定同一份模型。监听显示器参数变化，新增、更新或销毁面板。镜像屏共享系统桌面，保留镜像源的面板，由系统将画面复制到物理镜像屏。

## 3. 用户已确认的产品规格

1. 名称为 **DualDock**，仅供自己使用。
2. 应用组点击后横向展开一排，类似 Dockish。
3. 仅运行应用模式包括最小化、隐藏、其他桌面的普通应用，并将它们全部平铺。
4. 切回普通模式恢复固定应用与分组。
5. 在应用内提供隐藏系统 Dock 的选项。
6. 某屏进入 macOS 全屏应用时仅隐藏该屏 DualDock，其余屏保持显示。
7. 全部屏幕共享应用、分组、排列和显示模式。

## 4. 建议的开发方案

采用原生 Swift，AppKit 管理屏幕面板、弹窗和拖拽，ScreenCaptureKit 获取窗口缩略图，Accessibility 处理窗口激活。设置界面可用 SwiftUI。交付本地 `.app`、源码和一键构建运行脚本。用户已选择首次导入系统 Dock 的固定应用，随后在 DualDock 内独立维护，并提供重新导入按钮。

多屏与分组的数据集中保存在一个本地配置文件中，模型采用有类型的 app/group 条目与稳定 UUID。保存采用原子写入，编辑完成后所有屏幕一起刷新。分组支持创建、加入、移出、重命名和排序；仅运行模式不修改持久化布局。

悬停应用后显示该应用窗口的缩略图；对过时的异步请求使用代次校验，避免鼠标已经移到另一个应用后显示旧结果。优先在需要展示时截图，截图失败时显示窗口标题或应用图标。点击预览恢复并激活对应窗口。

隐藏系统 Dock 开关启用前保存有关偏好的原值和键是否存在，退出恢复本应用实际改动的值，提供手动恢复入口。恢复时检查当前值是否仍由本应用设置，避免覆盖用户随后修改的系统设置。

建议首版水平放在各屏底部，支持图标大小、两种模式、窗口预览和系统 Dock 隐藏开关。该位置及首版范围已由用户确认。

### 技术方案的选择

- 公开 API 方案采用标准窗口截图与 Accessibility，窗口 ID 匹配和逐屏全屏判断需要启发式方法。
- 原生接口为主、少量私有接口补足的方案，可在当前系统上更准确匹配预览窗口与检测全屏状态；私有接口需要动态探测、局部封装和失效回退，系统升级后可能需要适配。

用户已选择第二种，要求优先保证窗口切换和全屏判断准确，并为接口失效提供回退。

## 5. 最终范围确认

用户已经确认首次导入后独立维护、少量私有 API，以及底部横向的四项功能首版。普通模式为固定应用与分组在前，未包含的运行应用在分隔线后。废纸篓、最近应用和最小化窗口独立图标放在后续。

独立实施审查已完成，拖拽停留阈值、横向滚动和短期缓存由实现确定。

## 6. 本机验证与后续验收

开发环境为 macOS 27.0.1、Xcode 27.2、Swift 6.4.2、Apple M5。普通工具沙盒无法读取 GUI 会话，宿主只读探针能够正常访问。宿主当前报告一个逻辑显示器，1800×1169 pt，2× Retina，未镜像，screensHaveSeparateSpaces=false。

已有屏外截图成功的基础验证。DualDock 的辅助功能和屏幕录制权限需要以新应用身份授予，探针的授权状态不能代替。

交付前需要验证分组编辑持久化、模式往返、迟到预览丢弃、窗口激活、退出后系统 Dock 恢复。真实双屏同显、各屏独立全屏隐藏、镜像切换及显示器拔插恢复，需连接相应显示器后验收。

## 7. 分析限制

Hopper 对部分 Swift 函数生成重复控制流且不提供完整 body ranges。继续追踪分组回调时，REA/Hopper bridge 进入取消后仍 busy 的异常状态，GUI 日志报告 KeyboardInterrupt/SystemError。异常前的 38 条 Evidence 已完整导出。随后以常规 arm64 反汇编补查面板创建和私有窗口 ID 接口，结论在报告中单独标明来源。

调用 REA `close_binary` 返回 cleanup_incomplete，保留 `/tmp/rea-5DSN3e` 及分析文档。尝试保存 Hopper 文档时遇到试用版禁止保存提示，已取消关闭并保留未保存的 `image.hop` 窗口。可继续使用已导出的 Evidence JSON；没有将未成功返回的分析记为完成。

本报告用于独立实现 DualDock 的行为与系统集成，不将反编译伪代码视为可直接复用的产品源代码。
