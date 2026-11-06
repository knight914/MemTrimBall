# MemTrimBall

**源码版本 0.0.1，未编译、未安装、未经设备验收。** 独立的 MemTrim 扩展；不修改、覆盖、重新打包原 deb 或 MemTrimPrefs.bundle，不提供自己的内存清理算法。本次工作仅限本地源码；未执行 git、编译、上传、设备连接或安装。

## 已实现行为

- 设置 App 加载原 `MemTrimPrefs.bundle` 的 `MTPreferencesController` 后，通过 Substrate 包装 `specifiers`，保留原条目并追加“显示悬浮球”开关。只在 `com.apple.Preferences` 注入，并以 bundle 文件名及类名二次限定。
- 偏好 domain：`com.knight914.memtrimball`，`Enabled` 为 CFBoolean，缺失/类型错误即关闭。通知：`com.knight914.memtrimball.preferences-changed`。Settings 仅在同步成功后发送 Darwin 通知。
- 仅 `com.apple.springboard` 创建窗口；Settings 注入模块不创建窗口。
- 点击球发送 `notify_post("com.crctdd.memtrim.request.normal")`。
- 长按球 0.65 秒显示确认面板；只有点击“发送深度请求”才发送 `notify_post("com.crctdd.memtrim.request.deep")`。取消、锁屏、灭屏、安全区改变及旋转均撤销面板，不自动发送。
- 成功提示仅为“已请求 MemTrim；不代表清理完成”。`notify_post` 成功不代表守护进程存在、受理或清理完成，没有清理结果回执。
- 拖动使用窗口本地坐标，安全区内限制中心位置；中心接近左右安全边缘（48 pt 阈值）后收成 44×60 pt 把手，展开球 56×56 pt。把手不切出屏幕，保留至少 44 pt 点击宽度；点击把手只展开，不发送请求。位置和收纳状态持久化独立键，不覆盖 `Enabled`。
- `tap` 等待 pan/long-press 失败，所有识别器不同步；长按面板期间阻止球手势；拖动取消不落盘，旋转/安全区变化取消拖动。
- 不调用 `makeKeyWindow`、`makeKeyAndVisible`，窗口不可成为 key。仅球/把手或确认面板矩形命中，其余区域 `hitTest` 返回 nil，包括提示条。确认面板是窗口内自绘面板，不使用需要 key/presenter 的 UIAlertController；面板外触摸仍透传给下方应用。
- 无常驻轮询、无自动杀进程/删除缓存。唯一 `dispatch_after` 是 2.5 秒提示隐藏（非循环，weak 捕获及代次校验）。所有 UI、订阅回调和偏好刷新在主线程。

## 隐藏策略与真实边界

注册 Darwin 事件后立即取当前状态，同时观察 SpringBoard UIApplication 启动/激活及 protected-data 通知：

1. `com.apple.springboard.lockstate` 必须成功注册、读状态成功且值为 `0`；
2. `com.apple.iokit.hid.displayStatus` 必须成功注册、读状态成功且值为 `1`；
3. `SBLockScreenManager.sharedInstance.isUILocked` 必须存在、方法参数数及返回类型匹配并返回未锁定；
4. SpringBoard 必须已完成启动或已激活且存在非本扩展的系统窗口；`Enabled` 必须为真。

任一未知、API 缺失、注册失败、读取失败或非期望值都隐藏。初始在 `didFinishLaunching` 前加载时等待事件；在 SB 已启动后加载时立即检查现有 app/window/state，不仅依赖错过的启动通知。锁定/显示状态回调先隐藏并移除确认面板，再重新取当前状态；每次触摸和发送请求前再次检查。protected data 即将不可用时直接隐藏，不依赖其状态作为解锁证据。

**限制必须保留：**这些 Darwin 键/状态含义和私有 SBLockScreenManager ABI 是目标系统假设，不是已在当前设备验证的事实。`notify_get_state` 成功不能证明存在有效 publisher；初始显示状态默认 0 因而隐藏，但无法单凭 API 证明所有系统都不会保留旧状态。隐藏发生在主线程收到事件时，不能承诺屏幕电气状态变化的硬实时响应；若目标系统不发送这些事件、使用不同状态值或私有接口改变，可能一直隐藏或无法满足灭屏即时性，发布前必须核实。无“未知就显示”的回退，也没有通过轮询绕开验证。

窗口优先绑定前台 SpringBoard `UIWindowScene`，无可用 scene 时使用传统 UIWindow；由 UIKit root controller 接收旋转/安全区布局。SpringBoard 私有多 scene、iPad 分屏、Stage Manager、横屏锁屏、通知中心/控制中心层级、AOD、辅助功能及第三方覆盖窗口行为仍需真机验收。未添加任何“锁屏可见”私有窗口 flag。

## 文件

- `MTBBall.m`：SpringBoard 窗口、锁/显示事件、触摸、拖动、确认、请求及反馈。
- `MTBEdgeDock.h/.m`：既有贴边位置状态模型。
- `MTBPreferences.m`：既有设置内开关注入。
- `MTBBall.plist`、`MTBPreferences.plist`：互相隔离的注入 filter。
- `Makefile`、`control`、`VERSION`：Theos 工程与版本元信息。
- `.github/workflows/build.yml`：**强制阻断的 macOS 双环境设计草案**。
- `scripts/static_check.py`、`STATIC_CHECKS.md`：无编译静态检查与实际结果。
- `.gitignore`：排除产物、工具链、SDK 和常见凭据文件。

## 工程准备（说明，不表示已经执行）

rootless 的 Makefile 使用 `THEOS_PACKAGE_SCHEME=rootless`，工具链必须是独立准备的官方 `https://github.com/theos/theos`。目标声明为 iOS 15+、arm64/arm64e；`Architecture: iphoneos-arm64` 是 rootless 包模板，不是已经验证的产物架构。原 MemTrim 本地包声明 iOS 15–17、`iphoneos-arm64e`，本扩展沿用固件依赖范围不等于扩大原插件兼容性。

需要合法获得的 iOS SDK、支持 arm64e 的 clang/链接工具、Theos 的 Preferences 头/私有框架链接元数据及 substrate headers/library。当前主控不 hook SpringBoard 方法；设置模块链接 substrate 和 Preferences。`Makefile` 明确拒绝非 rootless scheme；**这不声称已经实现 roothide 可用构建**。

roothide 必须单独采用 `https://github.com/roothide/theos`；其 scheme、打包路径、substrate、PreferenceLoader、CFPreferences 与原 MemTrim 在对应环境的依赖/加载兼容性未核实，所以不得仅修改包架构、移动路径或改名字假装适配。

将来经授权构建时，需先记录版本占用及工具链 commit。当前 0.0.1 尚未占用编译；第一次编译可用 0.0.1，其后任何新编译尝试（含失败重试、Actions Re-run）都递增末位，并同步 `VERSION`、`control`。Makefile 检查两者一致，但**没有跨 CI 的版本分配器/不可复用账本**，因此不能视为发布防重保障。不要直接 Re-run 复用版本。

rootless 在上述条件满足且另外授权后使用标准命令 `make clean package FINALPACKAGE=1`。本次未运行此命令，不提供 deb，不声称任何环境编译成功。

## Actions 草案：不能用于构建

只有 `workflow_dispatch`，无 push/PR/schedule 触发。`preflight` 在 macOS runner 无条件 `exit 1`；依赖它的 rootless/roothide matrix 永远不能进入。输入、变量和 secret 均不能解锁。草案没有有效 checkout/SDK 下载/编译/upload steps，不冒充一个可用构建；手动触发即使失败仍可能消耗 runner 额度，本次未触发。

启用前必须在另一次明确授权的修改中完成：两个官方工具链及递归子模块 commit 固定、可信 Action SHA、合法 SDK 来源/Xcode/arm64e 验证、roothide 文档核对、各环境完全隔离的 workspace/staging/packages、持久化原子版本分配与重试策略、独立 artifacts 命名、包依赖/路径/架构核验、计费确认。不能只删除 preflight 就把占位 matrix 当成可用构建。

## 只读证据

本地 `/var/minis/shared/class-dump/com.crctdd.memtrim_0.0.1_iphoneos-arm64e/logs/` 的 `MemTrimPrefs.txt` 含 `MTPreferencesController` 和两种请求字符串；`MemTrimURL.dylib.txt`、`MemTrimClient.dylib.txt`、`memtrimd.txt` 交叉出现两种字符串。原 control 声明依赖 `mobilesubstrate`、`preferenceloader`，Package 为 `com.crctdd.memtrim`。这些只能证明本地样本内容；不等于验证了 daemon 实际运行或状态 API。未触碰原 deb。

## 验收清单（全部设备项目待验证）

1. 默认没有球；原 MemTrim 页显示一个开关，不改变原条目；连续重进不重复插入。
2. 开关两进程即时一致；不存在 daemon 或发送失败时无“清理完成”误报。
3. 球点击普通请求；长按只弹确认；取消不请求；确认每次只请求一次。
4. 左右收纳/点击展开无额外请求；自由位置、把手位置跨设置切换和重启保持。
5. 边角、刘海/灵动岛、横竖屏、安全区改变、拖动中旋转和长按/拖动冲突。
6. 球外/面板外触摸、输入法及原 app key window 不受影响。
7. 确认面板显示时锁屏/灭屏立即撤销；锁屏启动、解锁、AOD、SB 已/未启动加载、未知状态始终隐藏。
8. 分别在经核实的 rootless 和 roothide 工具链构建/验包/设备测试；不得用其中一个成功代替另一个。

## 关闭、卸载与恢复

在原 MemTrim 设置里关闭开关即隐藏并撤销确认。未来安装后若出现 SpringBoard 问题，使用越狱环境安全模式/禁用注入功能，卸载 `com.knight914.memtrimball`，不要卸载或修改原 MemTrim 来冒充本扩展恢复。模块卸载需由用户另外授权的正常包管理/桌面重载流程生效。偏好键可保留；需要清除时仅删除本扩展 domain，不触碰原插件 domain。此处为操作说明，本次未执行任何设备更改。
