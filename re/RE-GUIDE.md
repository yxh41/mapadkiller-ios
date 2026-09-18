# MapAdKiller-iOS 取证指南（怎么弄）

iOS 复刻不能复用 Android 的 hook 点（dex 混淆方法 ≠ iOS 的 Obj-C selector）。
通用两层（UIView 清扫 + SDK 自动拦截）**零逆向即可去广告**；
但要像 Android 那样精确命中"开屏闸门 / 首页 Banner 绑定"，需要你在真机把三家地图的
**广告类名 + selector** 取出来，填进 `Tweak.xm` 的 `installTargetedHooks()` 数组。

环境：iPhone 12 Pro / iOS 16.4.1 / Dopamine **roothide**。

---

## 方式 A：Frida（推荐，能批量列类+方法+视图树）

### 1. 越狱机装 Frida
Sileo 添加源 `https://build.frida.re`，安装 **Frida**（jailbreak 构建，自带 frida-server）。
装完 `frida-ps -U` 能列出进程即成功。

### 2. 电脑装 frida-tools（Windows）

> ⚠️ **别装进 WorkBuddy 沙箱**：frida 的 Windows wheel 约 47MB，沙箱实测下载只有 ~132KB/s（要跑几天），
> 所以这一步必须在你**自己的 PowerShell / CMD** 里做。

先找一个能用的 Python。如果 `py` / `python` 都提示"无法识别"，用本机已有的这份
（WorkBuddy 自带 Python 3.13.14 + pip 26.2.1，已验证可用）：

```powershell
# 一次性把工具目录挂到当前窗口的 PATH，之后 python / pip / frida-ps 都能直接敲
$env:PATH = "C:\Users\hxy24\.workbuddy\binaries\python\envs\default\Scripts;C:\Users\hxy24\.workbuddy\binaries\python\versions\3.13.12;" + $env:PATH
python -V
python -m pip -V
```

装 frida-tools（47MB，建议挂清华源，否则容易卡死）：

```powershell
python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple frida-tools
```

> frida 17.x 的 wheel 是 `cp37-abi3-win_amd64`，Python 3.13 可直接用，不存在版本冲突。
> 如果你机器上根本没有 Python：Microsoft Store 搜 **Python 3.12** 装上就会自动有 `py`；
> 或用 python.org 安装包（记得勾 `Add python.exe to PATH`）。

验证（手机插线、frida-server 在跑）：

```powershell
frida-ls-devices     # 能看到 usb/local 设备
frida-ps -U          # 应该能列出进程
```

- **USB 模式（`-U`）**：需要 Apple USB 驱动 / iTunes 提供 usbmuxd。
- **WiFi 模式**：见下面「方式 A2」。

---

## 方式 A2：WiFi 连接（不插线）

### 关键坑

**frida-server 默认只监听 `127.0.0.1:27042`**，USB 模式靠 usbmuxd 转发所以没事，
但 WiFi 直连必须让它监听全部网卡，否则 PC 连不上（表现为 `failed to connect` / 超时）。

### 1. 手机端：改成监听 0.0.0.0

用 SSH（`ssh root@<手机IP>`，默认密码 alpine）或手机上装 **NewTerm 3**（Chariz 源）：

```bash
su root                      # NewTerm 里需要先提权，密码 alpine
ps aux | grep frida-server
kill -9 <PID>                # 杀掉 launchd 拉起的旧进程
frida-server -l 0.0.0.0:27042 &
```

> roothide 下二进制路径会被重定位进 jbroot，`frida-server` 直接敲不通就先 `which frida-server`
> 拿真实路径。**重启后 launchd 会把它拉回默认监听**，需要再跑一次；
> 想一劳永逸就改 `re.frida.server.plist` 的启动参数（加 `-l 0.0.0.0`）。

### 2. 拿到手机 IP

设置 → Wi-Fi → 点当前网络右侧的 ⓘ → **IP 地址**（如 `192.168.1.23`）。
PC 与手机须**同一局域网**（同一 Wi-Fi）。

### 3. PC 端连通性测试

```powershell
Test-NetConnection 192.168.1.23 -Port 27042      # TcpTestSucceeded : True 即通
frida-ps -H 192.168.1.23:27042                   # 能列出进程就成功
```

### 4. 版本必须对齐（第二大坑）

**手机上的 frida-server 版本要和 PC 的 frida-tools 版本完全一致**，否则报
`Unsupported Frida version` 或连上秒断。

```bash
frida-server --version        # 手机端看，例如 17.18.0
```
```powershell
python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple frida-tools==17.18.0
```

### 5. 取证命令把 `-U` 换成 `-H`

```powershell
frida -H 192.168.1.23:27042 -n "高德地图" -l re\dump_classes.js
frida -H 192.168.1.23:27042 -n "高德地图" -l re\dump_views.js
```

### 连不上怎么排查

1. `Test-NetConnection <IP> -Port 27042` 不通 → frida-server 没监听 0.0.0.0，或没在跑。
2. 端口通但 frida 报错 → 99% 是版本不一致。
3. 都正常但 `-n "高德地图"` 找不到进程 → 先把 App 切到前台；
   或用 PID 附着更稳：先 `frida-ps -H 192.168.1.23:27042` 拿到 PID，再
   `frida -H 192.168.1.23:27042 -p <PID> -l re\dump_classes.js`。

### 2b. 你也可以完全不用电脑

如果觉得装 Python 麻烦，**只要视图树和类名**的话走方式 B（FLEX）就够了——
它整个跑在手机上，不需要电脑， flavour 无所谓。Frida 的优势是能一次性批量 dump 全部类+方法。

### 3. 取广告类 + 方法名
打开目标地图 App（如高德），另开终端：
```bash
frida -U -n "高德地图" -l re/dump_classes.js
```
脚本会枚举所有 Obj-C 类，筛出含 `Splash/Banner/Ad/GDT/CSJ/...` 的类，
并打印其**自身**方法里像广告入口的 selector（`loadAd/show/present/request/...`）。
把输出里你确认是广告的类 + 方法记下来。

### 4. 取视图树（定位开屏/Banner 的 view 类名）
```bash
frida -U -n "高德地图" -l re/dump_views.js
```
在开屏广告出现的瞬间跑（或首页 banner 出现时跑），看输出里带 `Ad/Banner/Splash`
的 view 类名与层级，对应到 `Tweak.xm` 的 `adNameMatch` token（如果类名没被命中就补 token）。

---

## 方式 B：FLEX（可视化，适合手动点）

Sileo 里若搜不到，先加源 `https://repo.chariz.com`（或 Havoc 源），再搜并安装 **FLEXalting**；
在它的 App 列表里勾选目标地图 App，`respring` 后打开该地图，**摇一摇**呼出悬浮面板：
- **View Hierarchy**：点开屏/Banner 视图 → 看 class 名（抄进 `adNameMatch` token 或视野清扫）
- **Runtime Headers**：搜 `Splash`/`Ad`/`Banner` → 看类的方法列表（抄 selector）
- **Network / Candidates**：辅助确认广告 SDK 厂商

---

## 5. 把结果填回 Tweak.xm

`installTargetedHooks()` 里按 App 填 `@[ClassName, selectorName]`：

```objc
if ([bundleID isEqualToString:kTargetAmap]) {
    hooks = @[
        @[@"AMapSplashViewController", @"viewDidLoad"],   // 例：开屏闸门
        @[@"AMapHomeBannerManager",    @"loadBanner"],    // 例：首页 banner 拉取
    ];
}
```

填完 `make` 推 CI 构建，装到机器，开 `DebugLog` 看 syslog：
- `targeted HOOKED ...` = 命中
- `targeted MISS ...`   = 类名/selector 写错或大版本混淆漂移（失效安全，不影响 App）

---

## 经验（来自 Android 版 ANALYSIS.md，iOS 同样适用）
- 广告多为服务端概率下发，"某次没广告"不能当验证依据 → 以 syslog 的 `HOOKED/VIEWKILL/SDK BLOCK` 为准。
- 大版本更新后混淆名会漂移 → 所有 hook 带 miss 日志，未命中不影响功能（fail-open）。
- 先靠通用两层（默认开）拿到立竿见影效果，再逐步补定点 hook，别一上来追求 100% 命中。
- 广点通(GDT)/穿山甲(CSJ/Pangle)/快手(KSAd)/百度(BUAd/Meridian) 在 iOS 上也有 SDK，
  类名特征基本一致，`adNameMatch` 的 token 已预置，通常 SDK 自动拦截层就能覆盖。
