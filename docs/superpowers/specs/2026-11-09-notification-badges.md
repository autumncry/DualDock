# 消息角标

用户要求同步系统 Dock 的应用通知数量，并在设置中提供显示开关。用户进一步确认，应用组收起时只显示红色叹号，单个 App 显示具体数量。

## 行为

- 默认开启“显示消息数量角标”，可以关闭并持久化选择。
- 单个应用显示系统实际提供的标签，空标签和零值不显示；不可读取时不生成虚假的0。
- 组内任一应用有有效提醒时，组图标显示“!”；展开后每个应用显示自己的标签。
- 每2秒后台读取，更新时只重绘已有图标，不重建 Dock、关闭预览或改变悬停几何。
- 关闭开关立即清除标签，停止定时读取，丢弃此前在途结果。重新开启必须使用新一代读取结果。

## 已核实的读取路径

LaunchServices 的 `_LSASNCreateWithPid` 与 `_LSCopyApplicationInformationItem` 在本机可动态解析。以 session=-2、key=StatusLabel 读取字典的字符串 label。Create/Copy 返回值按 retained ownership 接管。只依据 API 事实独立实现，没有复制 Docky 的 GPL 源码。

本机只读探针曾从 LS 与原生 Dock AXStatusLabel 同时读到飞书4、微信3，随后观察到微信标签自然清为空。实际新服务另一次读到飞书4、微信4，说明数据来自运行时，未硬编码示例数字。

优先采用 LS，以减少系统 Dock 隐藏或重启时 AX 数据暂时丢失的影响。LS 未提供标签时可用 AX 回退，严格通过 AXURL 的应用 bundle ID 对应；不按名称把同名微信辅助项覆盖主应用。AX 读取具有时间预算。数据不可用、没有角标、角标为明确空字符串分别处理。

REA 复用了原 Dockish Evidence 包，`Dockish/DockBadgeService.swift` 的证据为 `ev_0ea9a217b20fd6c457db4057513e1ab8606049eaa868055e0df0a936570cbb19`，地址 `0x10024a510`。有关 Docky 的 API 参考为 https://github.com/josejuanqm/docky/blob/main/Docky/Services/DockBadgeService.swift 与同仓库 `Private/LaunchServicesPrivate.swift`。

## 配置迁移

schema 3 加入 showBadges，旧配置缺该字段时采用开启默认值，保留已有分组、顺序与外观参数。备份文件采用当前 schema 编号，v2 升级前写入 configuration-before-v3.json。

## 验证

策略测试覆盖真实标签保留、空/零处理、严格应用身份、组叹号与禁用。服务替身测试覆盖后台读取、关闭清除、过期结果、重新开启、请求合并、权限/不可用状态与周期刷新。实际读取仅输出微信/飞书标签，没有读取或上传通知正文。
