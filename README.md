# MapAdKiller-iOS

把 Android Xposed/LSPosed 模块 [`yxh41/MapAdKiller`](https://github.com/yxh41/MapAdKiller) 复刻到 iOS 越狱环境，
去除**高德地图**的开屏广告与横幅广告。百度 / 腾讯地图的工程结构已就位，待填 hook。

目标环境：**iPhone 12 Pro / iOS 16.4.1 / roothide（Dopamine 兼容）**，arm64e。

---

## 三层防御（对应 Android 版架构）

| 层 | Android 原版 | iOS 实现 | 状态 |
|---|---|---|---|
| L1 | `ViewKiller`（遍历 DecorView 隐藏/移除广告 View） | `sweepView()`：递归 subviews，按类名 / accessibilityLabel 命中后隐藏 | ✅ 通用 |ws，按类名 / `accessibilityLabel` / `accessibilityIdentifier` 命中即 `hidden + removeFromSuperview` | ✅ 通用，无需逆向 |
| L2 | `SdkAutoBlock`（扫 dex 字符串找广告 SDK 并 no-op） | `blockAdSDKs()`：`objc_getClassList` 枚举全部类，命中后 `method_setImplementation` 把广告 selector 换成 no-op | ✅ 通用，无需逆向 |
| L3 | 逐 App 定点 hook | `installTargetedHooks()`：从砸壳 IPA 静态解析出的类 + selector | ✅ 高德已填（15.03.0） |
| L4 | `Config` 逐项 UI 去留 | `sweepUIItems()`：文案锚点 + 容器类名锚点，逐项隐藏 | ✅ 高德已校准 |

L1 / L2 是**零逆向**的通用层，任何 App 装上就能拿到效果。
L3 需要按版本获取 hook 点 —— 本项目用一个纯标准库的离线解析器搞定，**不需要 Frida、不需要 FLEX、不需要连接设备**。
L4 的锚点由真机日志反推，见下文「逐项 UI 去留」。

---

## 逐项 UI 去留（Layer 4）

面板里的 UI 项分两种，**数据源只有一份**：`re/gen_ui.py` 的 SPEC 表。

```
re/gen_ui.py  ──┬─> Preferences/Resources/Root.plist   设置面板
                └─> mak_ui_items.h                     Tweak.xm 引用的锚点宏
```

| 前缀 | 匹配方式 | 粒度 | 抗变更 |
|---|---|---|---|
| `ui_*` | UILabel / UIButton 文案**精确相等** | 单个入口（「消息」「优惠加油」…） | 弱 |
| `uic_*` | UIView 类名相等 | 整块容器（工具宫格、搜索栏、标签栏…） | **强** |

**为什么需要 `uic_*`**：真机日志证明首页工具宫格的条目是**服务端下发**的 ——
上一版日志里还有「实时公交」，下一版就变成了「秒送」。纯文案锚点必然持续漂移，
而容器类名（`GDLiteToolBoxView` / `GDLiteHomeCompanyView` / `WINQuickSearchBarV2`）
是写死在二进制里的。想要「不管它塞什么新词条进来都给我消失」，用 `uic_*` 这一组。

三条 fail-safe：

1. 所有项默认**显示**，只有用户显式关掉才隐藏；读不到偏好 = 全显示。
2. 文案只认**精确相等**，不做包含匹配 ——「打车」不会误伤叫「打车XYZ」的东西。
3. 命中文案后向上找容器最多 8 层，找不到就不藏 —— 宁可不藏也不误伤。
   隐藏一律只用 `hidden = YES`，**不** `removeFromSuperview`：列表 / 宫格 cell 复用时
   父视图仍按数据源持有它，硬摘会引发布局错乱甚至崩溃。

改 UI 项的正确姿势：改 `re/gen_ui.py` 里的 SPEC → 跑一次脚本 → 推。
**不要手改 `Root.plist` 或 `mak_ui_items.h`**（脚本内置交叉校验，两边数量对不上会直接失败）。

尚未校准： 「我的」页 6 项 + 首页信息流 9 项，锚点为空 = 不生效。
要补齐很简单：开 DebugLog，进高德翻一遍这两个页面，把日志里的 `UI TXT` 行发出来即可。
日志里的 `UI TXT`（短文案）和 `UI CLS`（类名）由 `makSniff()` 直接在高德进程内抄出来，
等价于用 Frida 抓视图树，但零依赖。

---

## 离线取证：有砸壳 IPA 就够了

```bash
python3 re/ipa_dump.py 高德地图_15.03.0.ipa --frameworks --objc
```

- 直接从 zip 内读 Mach-O，只加载需要的段，**不解压**整个 App（188MB 的包只读 ~24MB）
- 自动检查 `cryptid`，没砸壳会直接告诉你
- `--objc` 输出可直接粘进 `Tweak.xm` 的 NSArray 字面量
- 结果样例见 `re/amap_15.03.0_dump.txt`

**不要用子串匹配来找 "Ad"。** 这是本项目踩过的坑：

```
AMapAdapterNaviOverlay  -> 命中的是 Ada|pter        （导航图层，误伤会让地图不画线）
NXIRDownloadManager     -> 命中的是 Downlo|adManager
ACMUploadManager        -> 命中的是 ACMUplo|adManager
```

反过来 `containsString:@"SplashAd"` 又把整条 `WINSplash*` 开屏链路**全漏掉**。
正确做法是按驼峰拆段后做整段匹配 —— `ipa_dump.py` 和 `Tweak.xm` 里的逻辑完全一致。

### BundleID 提醒

实测「高德地图 15.03.0」砸壳包的 `Info.plist` 里是 **`com.autonavi.amap`**，
不是旧资料里常见的 `com.autonavi.minimap`。两个都已收进 `MapAdKiller.plist`。

---

## 构建

CI 用 **roothide 官方 theos 分支**（`roothide/theos`，内置 roothide package scheme），
`make package` 直接产出 `iphoneos-arm64e` 的 roothide `.deb`，不需要 patch.sh。
标准 `theos/theos` 没有 roothide scheme，不能用。

自动构建：Actions → `Build MapAdKiller (roothide)` → Run workflow。
每次构建会把 **commit 短哈希**注入 `control` 的 Version 和 `Tweak.xm` 的 `MAK_BUILD_TAG`，
装插件后在 syslog 里搜 `[MapAdKiller] loaded for` 就能看到 `build=v1+<hash>`，
用来确认机器上的 deb 到底是哪个 commit —— **别再装错版本**。

产物两路取件：Actions artifact `mapadkiller-deb`，或 `deb-artifacts` 分支的 `out/`。

---

## 关于 Cephei（重要）

本项目 **不依赖 Cephei**。原因是硬的：`roothide/theos` 的 `include/` 是空目录，
社区也没有 Cephei 的 roothide fork，CI 里 `#import <Cephei/HBPreferences.h>` 直接编译失败。

替代方案是**自写 PreferenceLoader bundle + 全局 plist 直写桥**
（仿 `yxh41/Oback` 的 `PrefsBridge`）：设置面板是一个编译型 bundle，
开关变更时由设置进程直写 `/var/mobile/Library/Preferences/com.yxh41.mapadkiller.plist`，
tweak 侧启动时 `gPrefs_load()` 读同一份文件。**已在真机验证链路通畅** ——
日志里出现 `ui items: hidden anchors=N` 就说明读到了。

偏好同时保持 fail-open：读不到就用编译期默认值，不会因读不到偏好而失效。

| 开关 | 默认值 | 说明 |
|---|---|---|
| `Enabled` / `ViewSweep` / `SdkBlock` | YES | 去广告层默认全开 |
| `Amap` / `Bmap` / `Tmap` | YES | 三个目标 App 全启用 |
| `Aggressive` | **NO** | 见下 |
| `DebugLog` / `FileLog` | NO | 日志开关 |

---

## 关于激进层（Aggressive）

安全层只断**数据 / 素材 / 标识**，让 App 自己判定"没有开屏广告"。

激进层直接 no-op `WINSplashScreenPresenter` 的展示闸门，效果更狠，但：
这些 `present` 方法带一堆 `completionBlock`，如果 App 拿它们等待开屏结束，
no-op 后理论上有卡在启动页的风险。**默认关闭**，确认安全层效果不够再单独打开。

---

## 已知限制

- hook 点来自 **15.03.0** 的静态解析。大版本更新后混淆类名可能漂移。
  所有 hook 都是 miss 即跳过（fail-open），失效表现为"又开始出广告"，不会崩 App。
  升级后重跑一次 `ipa_dump.py` 即可。
- 这个 IPA 是 **arm64** 切片，真机 App Store 版本是 arm64e；ObjC 元数据一致，hook 同样有效。
- 百度 / 腾讯地图的 L3 hook 待填，通用层（L1/L2）已经能覆盖一部分。

---

## 目录

```
Makefile                 Dahl roothide + arm64/arm64e，-Werror
control                  Depends: mobilesubstrate
MapAdKiller.plist        Filter：三家地图 bundle id
Tweak.xm                 四层实现 + 高德 hook 列表
mak_ui_items.h           由 re/gen_ui.py 生成的锚点表（ui_* 文案 / uic_* 类名）
Preferences/             编译型 PreferenceLoader bundle（自写，替代 Cephei）
  Resources/Root.plist   面板定义，同样由 re/gen_ui.py 生成
layout/                  bundle 的 Info.plist（bundle.mk 不会自动生成，必须由这里装上）
re/gen_ui.py             ★ UI 项单一数据源，改我这里
re/ipa_dump.py           离线静态取证（纯标准库，推荐）
```

> `re/` 是本地逆向脚本目录，不进仓库；里面提到的 Frida / FLEX 流程已被
> 「离线 ipa_dump.py」和「进程内 makSniff 日志嗅探」两条零依赖路径取代。

---

## 许可

沿用 Android 原版：GPL-3.0。
