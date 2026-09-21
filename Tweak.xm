// MapAdKiller-iOS — Tweak.xm
// 复刻 Android LSPosed 模块 yxh41/MapAdKiller 到 iOS 越狱（iOS 16 / roothide）。
//
// 架构映射（详见 README / RE-GUIDE.md）：
//   Android ViewKiller        -> UIView 树清扫引擎（按类名/accessibilityLabel/tag 隐藏移除）
//   Android SdkAutoBlock      -> Obj-C 运行时类枚举 + 广告方法 no-op（等价于 dex 扫字符串）
//   Android MainHook 派发      -> Filter.plist(3 bundle) + %ctor 按 bundle 守卫
//   Android Config RemotePrefs-> plist + 编译期默认值（roothide 下 Cephei 不可用，见下）
//   Android 定点 hook          -> installTargetedHooks() 运行时替换（见 placeholder，需真机 RE 后填）
//
// 约束：-Werror；禁止废弃 UIKit（keyWindow / windows / UI_USER_INTERFACE_IDIOM）。

// ⚠️ 不用 Cephei：roothide/theos 的 include/ 是空目录，社区也没有 Cephei 的 roothide
//    fork，CI 里 #import <Cephei/HBPreferences.h> 直接编不过。
//    所以偏好走「编译期默认值 + 运行时尽力罗追，追不到就用默认值」的 fail-open 设计：
//    只要 dylib 注入成功，即使一个字节的偏好都没读到，去广告也是默认全开的。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdarg.h>
// 由 re/gen_ui.py 生成，与 Preferences/Resources/Root.plist 同源，勿手改
#include "mak_ui_items.h"

// 构建标记：CI 会把 +<commit短哈希> 注入这里（见 .github/workflows/build.yml），
// 保证每个 deb 都能自报自己是哪个 commit —— 用户历史上多次装错版本，这个必须有。
#ifndef MAK_BUILD_TAG
#define MAK_BUILD_TAG @"v1"
#endif

#pragma mark - Targets & preference identifier

static NSString * const kTargetBmap = @"com.baidu.BaiduMap";
static NSString * const kTargetTmap = @"com.tencent.map";
static NSString * const kPrefID     = @"com.yxh41.mapadkiller";

// 高德 BundleID 有两代。实测「高德地图 15.03.0」砸壳包 Info.plist 里是
// com.autonavi.amap（不是旧资料里的 com.autonavi.minimap），两个都收，避免版本差异。
// 用 dispatch_once 而非 file-scope 字面量，免得在某些 clang 版本上踩 -Werror。
static NSArray<NSString *> *makAmapBundleIDs(void) {
    static NSArray<NSString *> *ids = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ids = @[ @"com.autonavi.amap", @"com.autonavi.minimap" ];
    });
    return ids;
}

static BOOL bidIsAmap(NSString *bid) {
    return bid.length > 0U && [makAmapBundleIDs() containsObject:bid];
}

#pragma mark - 配置（编译期默认 + 运行时尽力覆盖）
//
// 不用 Cephei：roothide/theos 的 include/ 是空目录，社区也没有 Cephei 的 roothide
// fork，CI 里 #import <Cephei/HBPreferences.h> 直接编不过。
// 所以偏好走「编译期默认值 + 运行时尽力罗追，追不到就用默认值」的 fail-open 设计：
// 只要 dylib 注入成功，即使一个字节的偏好都没读到，去广告也是默认全开的。
//
// 默认取舍原则（跟 Android 版 ViewKiller 的 fail-safe 一致）：
//   去广告三层默认全开；DebugLog 默认关（别天天刷日志）；
//   Aggressive 默认关（详见 installTargetedHooks 的风险说明）。

static BOOL gEnabled    = YES;  // 总开关
static BOOL gViewSweep  = YES;  // UIView 清扫层
static BOOL gSdkBlock   = YES;  // 广告 SDK 自动拦截层
static BOOL gAggressive = NO;   // 激进层：直接 no-op 开屏展示闸门
static BOOL gDebugLog   = NO;   // 调试日志（实时 syslog）
static BOOL gFileLog    = NO;   // 文件日志（独立开关，写到文件里给 Filza 翻）
static BOOL gAmap       = YES;
static BOOL gBmap       = YES;
static BOOL gTmap       = YES;

// Layer 4「逐项 UI 去留」用的状态（详见下方 makUIAnchors 注释）
static NSDictionary *gUIPrefs = nil;                  // 全局 plist 里 ui_* 键值（全量保留）
static NSSet<NSString *> *gUIHiddenAnchors = nil;     // 当前被关闭项的「中文文案锚点」集合
static NSSet<NSString *> *gUIHiddenClasses = nil;     // 当前被关闭项的「容器类名锚点」集合
// 已从父视图摘掉的视图会被这里**强持有**：AJX / 自绘引擎常用 unsafe 指针管理子视图，
// 摘掉后若没人持有就会释放，引擎下次再来 setFrame: 就是 EXC_BAD_ACCESS。
// 代价只是留住几十个隐藏视图（几 KB），换来的是绝对不会崩。
static NSMutableSet<UIView *> *gGraveyard = nil;     // 摘掉的视图「墓地」，防悬垂

// 参与匹配 / 嗅探的文案长度上限。嗅探与匹配必须**共用同一个常量** ——
// 历史上两处各写各的（8 / 16），结果长文案「能被嗅探抓到、却永远匹配不上」，
// 用户翻开关毫无反应，且这种 bug 在代码里看不出来。
// 24 覆盖实测最长的「俺叫熊大，俺带你去狗熊岭瞧瞧？」这类活动推荐流文案。
#define MAK_TXT_MAX 24U
static void makUIRecompute(void);                     // 前向声明（定义在 Layer 4 区段）

static BOOL makBool(NSDictionary *dict, NSString *key, BOOL fallback) {
    id v = [dict objectForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        if ([s isEqualToString:@"yes"] || [s isEqualToString:@"true"] || [s isEqualToString:@"1"]) return YES;
        if ([s isEqualToString:@"no"]  || [s isEqualToString:@"false"] || [s isEqualToString:@"0"]) return NO;
    }
    return fallback;
}

// 尽力从 plist 读一次偏好（roothide 下 App Store App 多数读不到这些路径）。
// 读不到就保持上面的默认值 —— 绝不会因为读配置失败导致"不去广告"。
static void gPrefs_load(void) {
    NSDictionary *d = nil;
    NSString *fn = [kPrefID stringByAppendingString:@".plist"];
    NSArray<NSString *> *paths = @[
        [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:fn],
        [@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:fn],
    ];
    for (NSString *p in paths) {
        NSDictionary *t = [NSDictionary dictionaryWithContentsOfFile:p];
        if (t.count > 0U) { d = t; break; }
    }
    if (!d) return;   // 保持默认值
    gEnabled    = makBool(d, @"Enabled",    gEnabled);
    gViewSweep  = makBool(d, @"ViewSweep",  gViewSweep);
    gSdkBlock   = makBool(d, @"SdkBlock",   gSdkBlock);
    gAggressive = makBool(d, @"Aggressive", gAggressive);
    gDebugLog   = makBool(d, @"DebugLog",   gDebugLog);
    gFileLog    = makBool(d, @"FileLog",    gFileLog);
    gAmap       = makBool(d, @"Amap",       gAmap);
    gBmap       = makBool(d, @"Bmap",       gBmap);
    gTmap       = makBool(d, @"Tmap",       gTmap);

    // ui_* 是 Layer 4 逐项去留的键；缺任何一项都按「显示」处理（fail-safe）
    gUIPrefs    = d;
    makUIRecompute();
}
#pragma mark - 文件日志（独立开关 FileLog，默认关）
//
// 为什么要落文件：iOS 10+ 已经没有 /var/log/syslog，只剩统一日志（os_log）实时流，
// 必须连电脑抓；本机若没装 iTunes / Apple 驱动就根本抓不到。落文件后手机上 Filza 直接翻，
// 还能看历史 —— 排查「偏好链路通不通」「装错版本」这类要反复重启 App 的问题特别省事。
//
// ⚠️ 沙箱前提（关键，别写死路径）：dylib 注入在高德（App Store App）进程里，**继承它的沙箱**，
//    /var/mobile/ 下的路径并不保证可写（上面 gPrefs_load 读同一片区域都标注了「多数读不到」）；
//    roothide 还额外有 per-app 路径重定向。所以这里**依次探测多个候选**，
//    最后兜底到 App 自己的容器 Documents（一定能写，只是路径带 UUID，Filza 里搜一下）。
//
// 三重约束：
//   1) 默认关（独立开关 FileLog，不复用 DebugLog）
//   2) 缓冲写：攒满 8 行、或距上次落盘超过 2 秒才写，绝不在 sweep 热路径里同步落盘
//   3) 限大小：超过 256KB 就截断保留最后 192KB，避免放几天涨到几百 MB
//   全路径都写不进 => 静默关闭文件日志，不影响任何去广告功能（fail-open）。

static NSString *gLogPath = nil;                  // 实际生效的日志文件路径
static NSMutableArray<NSString *> *gLogBuf = nil; // 写缓冲
static NSTimeInterval gLogLast = 0.0;             // 上次落盘时间戳

static BOOL makWritable(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:path]) {
        return ([NSFileHandle fileHandleForWritingAtPath:path] != nil);
    }
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

// 依次探测候选路径，返回第一个可写的；全失败返回 nil
static NSString *makLogResolve(void) {
    NSMutableArray<NSString *> *cands = [NSMutableArray arrayWithArray:@[
        @"/var/mobile/Documents/MapAdKiller.log",
        @"/var/jb/var/mobile/Documents/MapAdKiller.log",
        @"/var/mobile/Library/Logs/MapAdKiller.log",
    ]];
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count > 0U) {
        [cands addObject:[docs.firstObject stringByAppendingPathComponent:@"MapAdKiller.log"]];
    }
    for (NSString *c in cands) {
        if (makWritable(c)) return c;
    }
    return nil;
}

static void makLogFlush(void) {
    if (!gFileLog || gLogPath.length == 0U || gLogBuf.count == 0U) return;
    NSString *chunk = [gLogBuf componentsJoinedByString:@""];
    [gLogBuf removeAllObjects];
    @autoreleasepool {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!h) return;
        [h seekToEndOfFile];
        [h writeData:[chunk dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
        NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:gLogPath error:NULL];
        unsigned long long sz = [[attr objectForKey:NSFileSize] unsignedLongLongValue];
        if (sz > 256ULL * 1024ULL) {   // 限大小：只留最后 192KB
            NSFileHandle *r = [NSFileHandle fileHandleForReadingAtPath:gLogPath];
            if (r) {
                [r seekToFileOffset:(unsigned long long)(sz - 192ULL * 1024ULL)];
                NSData *tail = [r readDataToEndOfFile];
                [r closeFile];
                [tail writeToFile:gLogPath atomically:YES];
            }
        }
    }
}

// 追加一行到缓冲（带时间戳）；按阈值落盘
static void MAKWrite(NSString *msg) {
    if (!gFileLog || msg.length == 0U) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogPath = makLogResolve();
        if (gLogPath.length > 0U) {
            NSLog(@"[MapAdKiller] log file: %@", gLogPath);   // 明确告诉用户去哪看
        } else {
            NSLog(@"[MapAdKiller] log file: 无可用可写路径，文件日志已关闭");
            gFileLog = NO;
        }
    });
    if (gLogPath.length == 0U) return;
    if (!gLogBuf) gLogBuf = [NSMutableArray array];
    NSDate *now = [NSDate date];
    NSTimeInterval t = [now timeIntervalSince1970];
    [gLogBuf addObject:[NSString stringWithFormat:@"%@ %@\n", now.description, msg]];
    if (gLogBuf.count >= 8U || (t - gLogLast) > 2.0) {
        gLogLast = t;
        makLogFlush();
    }
}

static void MAKLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gDebugLog) NSLog(@"[MapAdKiller] %@", msg);
    MAKWrite(msg);   // 文件日志与 DebugLog 独立：FileLog 开着就写，不要求同时开 DebugLog
}

// 无条件打印（同时进 syslog 与文件）
static void MAKNote(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[MapAdKiller] %@", msg);
    MAKWrite(msg);
}

#pragma mark - 广告类名 / selector 特征词（等价 Android AD_TOKENS / SDK_PREFIXES）
//
// ⚠️ 血泪教训：绝对不要用 containsString 去匹配 "Ad" / "AdManager" 这类子串。
//    高德真实类名里这些全是误伤：
//      AMapAdapterNaviOverlay   -> 命中的是 Ada|pter          （导航图层，误伤会导致地图不画）
//      NXIRDownloadManager      -> 命中的是 Downlo|adManager
//      ACMUploadManager         -> 命中的是 ACMUplo|adManager
//    反过来，containsString:@"SplashAd" 又把 WINSplash* 整条开屏链路漏光了。
//    正确做法：先按驼峰拆成独立词段，再做整段匹配。
//
// ⚠️ 血泪教训 v2（真机日志 2026-09：868 条 SDK BLOCK / 107 个类，77 个是误伤）：
//    只做「词段匹配」完全不够 —— 高德进程里同时装着系统私有框架，一批长得很像广告的
//    系统类被一起 no-op，直接把蓝牙 / 隔空投送 / NFC / 实时路况弄坏：
//      CBAdvertiser / CUBLEAdvertiser / CUBonjourAdvertiser / CUNFCAdvertiser
//      PKProximityAdvertiser / SFBLEAdvertiser / TSBonjourAdvertise
//        -> Advertising 在这里是「广播」不是「广告」（Continuity / Handoff / 隔空投送）
//      GEOTrafficBannerText（56 个方法）      -> 实时路况横幅，不是广告
//      ADClient / ADAttribution / ADCoreSettings / ADBannerView（iAd 框架）
//      ASCAdLockupView / MHSchemaMHAdMatchingEnded（App Store 搜索广告 / Siri）
//      AFSDK*（AppsFlyer 归因，不是广告展示）
//      SF*/CK*/NM*/BN*/PX* 一堆 Banner / Popup（Safari / 信息 / 新闻 / 照片的 UI 横幅）
//    根因：banner / advert / popup 是**多义词**，且进程里绝大多数类不来自 App 本体。
//
// 修复 = 三道闸门，全部通过才允许 no-op（见下方 makImageAllowed / adNameMatch）：
//   1 来源：类必须由 App 本体 / App 自带 framework 加载（class_getImageName 判定）
//   2 黑名单：命中广播语义词段（Advertiser / BLE / Bonjour / NFC / Proximity）直接放行
//   3 强弱：强令牌单独命中即算；弱令牌需厂商词根或自家前缀背书

static NSArray<NSString *> *makCamelSegs(NSString *name) {
    // AMapAdapterNaviOverlay -> ["A","Map","Adapter","Navi","Overlay"]
    // WINADView              -> ["WINAD","View"]
    static NSRegularExpression *rx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rx = [NSRegularExpression regularExpressionWithPattern:
              @"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+"
                                                      options:0 error:nil];
    });
    if (name.length == 0U || !rx) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSArray<NSTextCheckingResult *> *ms =
        [rx matchesInString:name options:0 range:NSMakeRange(0U, name.length)];
    for (NSTextCheckingResult *m in ms) {
        if (m.range.length > 0U) [out addObject:[name substringWithRange:m.range]];
    }
    return out;
}

// ---- 强令牌：单独命中即可判定为广告（语义唯一，不会是别的东西）----
static NSSet<NSString *> *makStrongTokens(void) {
    static NSSet<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"ad", @"ads", @"adview", @"adslot", @"adkit", @"admanager",
            @"adloader", @"addata", @"admodel", @"adconfig", @"adservice",
            @"adrequest", @"adresponse", @"adsdk", @"adx", @"adz", @"adunion",
            @"adprovider", @"adbanner", @"adsplash", @"adresource",
            @"admaterial", @"adtrack", @"splashad", @"nativead", @"popupad",
            @"interstitial", @"rewardvideo", @"rewarded"
        ]];
    });
    return s;
}

// ---- 弱令牌：多义词，必须「同时」命中厂商词根或自家前缀才成立 ----
//     banner / splash / popup / promo 在系统 UI 里遍地都是（Safari 横幅、通知横幅、
//     路况条、弹窗管理器…），单独出现不能当作广告证据。
static NSSet<NSString *> *makWeakTokens(void) {
    static NSSet<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"banner", @"splash", @"popup", @"pop", @"promo", @"promotion",
            @"reward", @"native", @"advert", @"advertise", @"advertising",
            @"advertisement"
        ]];
    });
    return s;
}

static NSArray<NSString *> *makVendorStems(void) {
    static NSArray<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = @[
            @"gdt", @"csj", @"pangle", @"buad", @"ksad", @"meridian",
            @"gromore", @"anythink", @"sigmob", @"beizi", @"mintegral",
            @"inmobi", @"vungle", @"unityads", @"applovin", @"ironsource",
            @"admob", @"mopub", @"tanx", @"omsdk", @"pubnative", @"suyi",
            @"taku", @"adscope", @"klevin"
        ];
    });
    return s;
}

// ---- 自家前缀：地图 App 自己的广告类命名前缀（弱令牌的「担保人」）----
static NSArray<NSString *> *makOwnPrefixes(void) {
    static NSArray<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = @[
            @"win",         // 高德 WIN*：WINSplash* / WINADView / WINTrainPicBannerView
            @"amaos",       // 高德 AMAOSBanner*
            @"amap",        // 高德 AMap*
            @"afcxbs",      // 高德 AFCXbsBanner
            @"ltmtoolbox"   // 高德 LTMToolBoxPopup*
        ];
    });
    return s;
}

// ---- 广播语义黑名单（词段级）：Advertising 在这里是「广播」不是「广告」----
static NSSet<NSString *> *makDenySegs(void) {
    static NSSet<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"advertiser", @"ble", @"bonjour", @"nfc", @"proximity",
            @"bluetooth", @"handoff", @"continuity", @"airdrop", @"nearby",
            @"beacon"
        ]];
    });
    return s;
}

// ---- 整名子串黑名单（跨词段的固定词组）----
static NSArray<NSString *> *makDenyWords(void) {
    static NSArray<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = @[ @"geotraffic", @"afsdk", @"appsflyer" ];
    });
    return s;
}

#pragma mark - 闸门 1：类来源判定（只碰 App 本体自带的类）

static NSString *makAppPathPrefix(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *b = NSBundle.mainBundle.bundlePath;
        if (b.length > 0U) p = [b copy];
    });
    return p;
}

// 类来自哪里？系统框架（dyld shared cache 里那一大批）一律放行不碰。
static BOOL makImageAllowed(const char *img) {
    if (img == NULL || img[0] == '\0') return NO;   // 来源不明 = 不碰
    NSString *p = [NSString stringWithUTF8String:img];
    if (p.length == 0U) return NO;                  // 非 UTF-8 路径 = 不碰
    if ([p hasPrefix:@"/System/"] || [p hasPrefix:@"/usr/"] ||
        [p hasPrefix:@"/AppleInternal/"] || [p hasPrefix:@"/Developer/"]) {
        return NO;
    }
    NSString *app = makAppPathPrefix();
    if (app.length > 0U) return [p hasPrefix:app];  // 必须是 App 本体 / 自带 framework
    return YES;                                     // 拿不到 bundle 路径时，至少已排除系统库
}

static BOOL makClassAllowed(Class c) {
    if (c == Nil) return NO;
    return makImageAllowed(class_getImageName(c));
}

static BOOL makViewAllowed(UIView *v) {
    if (v == nil) return NO;
    if (makClassAllowed([v class])) return YES;
    return makClassAllowed(object_getClass(v));   // KVO 动态子类兜底
}

// 单个驼峰段是否本身是广告词
// ⚠️ 只在「类已被判定为广告类」之后用于 selector 匹配；弱令牌在这里可以单独成立，
//    因为上下文已经是 WINSplash*/AMAOSBanner* 这类明确的广告类了。
static BOOL segIsAdToken(NSString *seg) {
    NSString *low = seg.lowercaseString;
    if ([makStrongTokens() containsObject:low]) return YES;
    if ([makWeakTokens() containsObject:low]) return YES;
    for (NSString *v in makVendorStems()) {
        if ([low isEqualToString:v]) return YES;
        if ([low hasPrefix:v] && (low.length - v.length) <= 6U) return YES;
    }
    return NO;
}

static BOOL adNameMatch(NSString *name) {
    if (name.length < 4U) return NO;
    NSString *nm = name;
    while ([nm hasPrefix:@"_"]) nm = [nm substringFromIndex:1U];   // __AJXxx / _TtCxx
    if (nm.length < 4U) return NO;
    // 绝不碰系统框架类（等价 Android isSdkClass 闸门，防全局误伤）
    // ⚠️ "AD" 单独作为前缀是 iAd / AppleDepth 的地盘（ADClient、ADCamera、ADAttribution…），
    //    真机日志里光 AppleDepth.framework 就贡献了 58 个这样的类。
    //    真正的广告 SDK 类名基本都带厂商前缀（GAD*/BUAd*/CSJ*），不会裸奔一个 AD 开头。
    if ([nm hasPrefix:@"UI"] || [nm hasPrefix:@"NS"] || [nm hasPrefix:@"CA"] ||
        [nm hasPrefix:@"CG"] || [nm hasPrefix:@"WK"] || [nm hasPrefix:@"MK"] ||
        [nm hasPrefix:@"CL"] || [nm hasPrefix:@"AV"] || [nm hasPrefix:@"CT"] ||
        [nm hasPrefix:@"CF"] || [nm hasPrefix:@"SK"] || [nm hasPrefix:@"PH"] ||
        [nm hasPrefix:@"AD"]) {
        return NO;
    }
    NSString *low = nm.lowercaseString;
    for (NSString *d in makDenyWords()) {
        if ([low rangeOfString:d].location != NSNotFound) return NO;
    }
    NSArray<NSString *> *segs = makCamelSegs(nm);
    // 广播语义黑名单优先：命中直接放行（蓝牙 / 隔空投送 / NFC / 附近设备）
    for (NSString *sg in segs) {
        if ([makDenySegs() containsObject:sg.lowercaseString]) return NO;
    }
    BOOL vendorHit = NO;
    for (NSString *sg in segs) {
        NSString *l = sg.lowercaseString;
        for (NSString *v in makVendorStems()) {
            if ([l isEqualToString:v] || ([l hasPrefix:v] && (l.length - v.length) <= 6U)) {
                vendorHit = YES;
                break;
            }
        }
        if (vendorHit) break;
    }
    BOOL ownHit = NO;
    for (NSString *p in makOwnPrefixes()) {
        if ([low hasPrefix:p]) { ownHit = YES; break; }
    }
    // 强令牌：单独命中即成立
    for (NSString *sg in segs) {
        if ([makStrongTokens() containsObject:sg.lowercaseString]) return YES;
    }
    // 全大写粘连段收尾：WINAD -> AD（WINADView / WINADTracker 这类老命名）
    for (NSString *sg in segs) {
        if (sg.length <= 2U) continue;
        BOOL allUpper = YES;
        for (NSUInteger i = 0U; i < sg.length; i++) {
            unichar c = [sg characterAtIndex:i];
            if (c < 'A' || c > 'Z') { allUpper = NO; break; }
        }
        if (!allUpper) continue;
        for (NSString *suf in @[ @"AD", @"ADS", @"SPLASH", @"BANNER", @"POP", @"PROMO" ]) {
            if ([sg hasSuffix:suf] && sg.length > suf.length) return YES;
        }
    }
    // 弱令牌：需要厂商词根或自家前缀背书
    if (vendorHit || ownHit) {
        for (NSString *sg in segs) {
            if ([makWeakTokens() containsObject:sg.lowercaseString]) return YES;
        }
    }
    return NO;
}

// 广告方法特征（等价 Android AD_METHODS）
// 同样按驼峰段匹配：这样才能命中 presentSplashScreenWithData: 这类真实 selector，
// 又不会把 setAddress: / reloadData 这种含 "ad" 的普通方法误伤。
static BOOL isAdSelector(NSString *selName) {
    if (selName.length == 0U) return NO;
    NSString *base = [[selName componentsSeparatedByString:@":"] firstObject];
    if (base.length == 0U) return NO;
    for (NSString *sg in makCamelSegs(base)) {
        if (segIsAdToken(sg)) return YES;
    }
    return NO;
}

// 通用 no-op：返回 nil（void/id 方法均安全；标量返回方法极少出现在广告展示路径）
static id adNoOp(id self, SEL _cmd, ...) {
    return nil;
}

static void noOpMethod(Class c, SEL sel) {
    if (!c || !sel) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) m = class_getClassMethod(c, sel);
    if (!m) {
        MAKLog(@"targeted MISS %@ %@", NSStringFromClass(c), NSStringFromSelector(sel));
        return;
    }
    method_setImplementation(m, (IMP)adNoOp);
    MAKLog(@"noOp OK %@ %@", NSStringFromClass(c), NSStringFromSelector(sel));
}

#pragma mark - Layer 1: UIView 树清扫引擎（Android ViewKiller 等价）

static void sweepView(UIView *view) {
    if (!view) return;
    NSArray<UIView *> *subs = view.subviews;
    for (UIView *v in subs) {
        sweepView(v); // 先递归子树
        NSString *cls = NSStringFromClass(v.class);
        BOOL hit = NO;
        if (adNameMatch(cls) && makViewAllowed(v)) hit = YES;   // 只藏 App 自带的广告视图
        if (!hit) {
            NSString *label = v.accessibilityLabel;
            if (label.length > 0U && label.length <= 6U) {
                NSString *low = label.lowercaseString;
                if ([label containsString:@"广告"] || [low isEqualToString:@"ad"] ||
                    [low isEqualToString:@"ads"]) {
                    hit = YES;
                }
            }
        }
        if (!hit) {
            NSString *aid = v.accessibilityIdentifier;
            if (aid.length > 0U && adNameMatch(aid)) hit = YES;
        }
        if (hit) {
            MAKLog(@"VIEWKILL %@ label=%@ id=%@", cls, v.accessibilityLabel, v.accessibilityIdentifier);
            v.hidden = YES;
            [v removeFromSuperview];
        }
    }
}

static void sweepKeyWindow(void) {
    UIWindow *win = nil;
    // 不用废弃的 -[UIApplication keyWindow]；走 connectedScenes
    NSArray<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
    for (UIScene *sc in scenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (!win) {
        // 兜底：取第一个 window scene 的 windows
        for (UIScene *sc in scenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            if (ws.windows.count > 0U) { win = ws.windows.firstObject; break; }
        }
    }
    if (win) sweepView(win);
}

#pragma mark - Layer 4: 逐项 UI 去留（对齐 Android Config.java 的 tab_* / tool_* / my_*）
//
// Android 的做法：AJX 卡片挂在 RecyclerView adapter 上，用「中文文案锚点」在
// onBindViewHolder 绑定完成的那一帧隐藏 —— 卡片一次都不会被绘制（README:38-39）。
// iOS 端在拿到真机视图树之前无从得知 cell 适配器，这里先用同样可靠的「精确文案锚点」
// 做等价实现：遍历 UILabel / UIButton，文案与目标项**精确相等**时，向上找到最近的
// 可藏容器（标签栏按钮 / UICollectionViewCell / UITableViewCell / UIButton）再隐藏。
//
// 三重 fail-safe：
//   1) 所有项默认「显示」，只有用户显式关掉才隐藏；读不到偏好 = 全显示。
//   2) 向上找容器最多 8 层，找不到就不藏 —— 避免误伤地图画布里的 POI 文字标注。
//   3) 文案用「精确相等」而非包含匹配，"打车" 不会误伤某个叫 "打车XYZ" 的东西。
//
// ⚠️ 锚点来源：标签栏 / 工具宫格的文案直接取自 Android 版 Config.TABS / Config.TOOLS
//    （同一产品两端文案一致），这部分可靠、立即生效。
//    「我的」页与信息流的锚点需要用 re/dump_views.js 取真机文案后再填，
//    那 15 项目前是空锚点 = 不生效（不会瞎藏），等 B 步骤校准。
//
// ⚠️ 另一个前置条件：本层依赖 Layer 4 能读到全局 plist。若 roothide 下 Settings
//    写入 / 高德读取这条链路失效，则全部项维持默认「显示」（去广告三层不受影响）。
//    装机后开 DebugLog 看有没有 "ui items: hidden anchors=N" 即可确认链路是否通。

// ⚠️ 这张表不再手写在 Tweak.xm 里 —— 面板开关和文案锚点必须永远一致，否则会出现
//    「面板上有开关、点了没反应」这种最难排查的假象。现在两者都由 re/gen_ui.py 从同一份
//    SPEC 表生成：Preferences/Resources/Root.plist（面板）+ mak_ui_items.h（这张表）。
//    改 UI 项请改 re/gen_ui.py 里的 SPEC，然后重跑一次脚本，别直接动这两个产物。
static NSDictionary<NSString *, NSArray<NSString *> *> *makUIAnchors(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = MAK_UI_ITEMS;
    });
    return m;
}

// 类名锚点（uic_*）：整块容器一起隐藏。注释见 re/gen_ui.py 顶部的说明。
static NSDictionary<NSString *, NSArray<NSString *> *> *makUIClassAnchors(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = MAK_UI_CLASS_ITEMS;
    });
    return m;
}

// 工厂默认值（MAK_UI_DEFAULTS，与面板同源由 re/gen_ui.py 生成）：
// 用户的偏好 plist 里查不到这个键时的裁决依据。
// 没有这一层，新版本新加的 UI 项对老用户**永远不生效** —— plist 里没这个键，
// 一律按「没配过 = 显示」兜底，用户必须手动翻一次开关才看得见效果。
// 2026-09-21：uic_feed_promo 连着两轮日志都是 classes=0，就是栽在这里。
static BOOL makUIFactoryVisible(NSString *key) {
    NSNumber *v = MAK_UI_DEFAULTS[key];
    return v ? [v boolValue] : YES;
}

// 只有用户显式关掉（NO / 0 / false）才算隐藏；没配过 = 用工厂默认；再兜底 = 显示
static BOOL makUIVisible(NSString *key) {
    id v = [gUIPrefs objectForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        if ([s isEqualToString:@"no"] || [s isEqualToString:@"false"] || [s isEqualToString:@"0"]) return NO;
        return YES;
    }
    return makUIFactoryVisible(key);
}

// 偏好变化后重算「要隐藏的文案集合 / 类名集合」。两个都空 => 清扫时直接早退，零开销。
static void makUIRecompute(void) {
    NSMutableSet<NSString *> *hid = [NSMutableSet set];
    NSMutableSet<NSString *> *cls = [NSMutableSet set];
    void (^collect)(NSDictionary *, NSMutableSet *) =
        ^(NSDictionary<NSString *, NSArray<NSString *> *> *table, NSMutableSet<NSString *> *into) {
        [table enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray<NSString *> *anchors,
                                                   __unused BOOL *stop) {
            if (anchors.count == 0U) return;   // 锚点未校准 -> 不参与
            if (makUIVisible(key)) return;     // 用户没关   -> 保持显示
            for (NSString *a in anchors) {
                if (a.length > 0U) [into addObject:a];
            }
        }];
    };
    collect(makUIAnchors(), hid);
    collect(makUIClassAnchors(), cls);
    gUIHiddenAnchors = (hid.count > 0U) ? [hid copy] : nil;
    gUIHiddenClasses = (cls.count > 0U) ? [cls copy] : nil;
    MAKLog(@"ui items: hidden anchors=%lu classes=%lu",
           (unsigned long)hid.count, (unsigned long)cls.count);
}

// 命中判定：只认「精确相等」，不做包含匹配
static NSString *makMatchedAnchor(UIView *v) {
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        t = ((UILabel *)v).text;
    } else if ([v isKindOfClass:[UIButton class]]) {
        t = [((UIButton *)v) titleForState:UIControlStateNormal];
    }
    if (t.length == 0U) {
        // 兜底：无障碍 label（AJX 渲染的控件常常只在 accessibilityLabel 上带文案）
        // 上限必须与 makSniff 的采集上限（MAK_TXT_MAX=24）一致 —— 历史上这里写 8，
        // 结果「加油、洗车优惠点这里」「做达人，免费领大额权益」这类长文案
        // **能被嗅探抓到、却永远匹配不上**，用户翻了开关也毫无反应。
        // 匹配本身是精确相等（containsObject:），放宽长度不会带来误伤。
        NSString *al = v.accessibilityLabel;
        if (al.length > 0U && al.length <= MAK_TXT_MAX) t = al;
    }
    if (t.length == 0U) return nil;
    NSString *s = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length == 0U) return nil;
    return [gUIHiddenAnchors containsObject:s] ? s : nil;
}

// 从命中的文案向上找最近的可藏容器；找不到返回 nil（fail-open，宁可不藏也不误伤）
//
// ⚠️ 真机校准（2026-09-19 UI CLS 行）之前的写法只认 "TabBarButton"，
//    但高德 iOS 的标签栏容器实际叫 **WINTabBarItem / WINTabBarSubItem**，
//    根本没有 "TabBarButton" 这四个字 —— 所以即使文案命中了也一律走到 UI SKIP。
//    这里改成「名字模式 + cell + 尺寸受限的 UIControl」三重判定：
//      · 名字模式：真机出现过且粒度正确的容器
//      · cell：列表 / 宫格的标准容器
//      · UIControl：兜底，但要求宽度不超过屏幕 60%，防止把整条 WINTabBar 端掉
static UIView *makVictimContainer(UIView *start) {
    static NSArray<NSString *> *pats = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pats = @[
            @"TabBarButton",   // iOS 原生 UITabBarButton
            @"TabBarItem",     // 高德 WINTabBarItem
            @"TabBarSubItem",  // 高德 WINTabBarSubItem
            @"ItemView",       // 高德 GDLiteHomeCompanyItemView
            @"ToolBox",        // 高德 GDLiteToolBoxView
            @"WidgetView",     // 地图浮层小组件
            @"VerticalScrollRow" // 首页滚动词条
        ];
    });
    CGFloat maxW = UIScreen.mainScreen.bounds.size.width * 0.6;
    CGFloat maxH = UIScreen.mainScreen.bounds.size.height * 0.5;
    //
    // ⚠️ 真机校准（2026-09-20 第十五轮）：用户反馈「有些只隐藏了名字」。
    //    第十三轮日志（ca451bb，我的页 POLL）给出确切证据：
    //      UI HIDE anchor=领油券 victim=AJXContainerView w=36
    //        chain=AJXLabel(36w) < AJXContainerView(36w) < AJXContainerView(36w) < ...
    //      → 藏到的只是**包着文字的小容器**，图标和整条还在，用户看到的就是「名字没了」。
    //    而「我的」页宫格的真实粒度是：
    //      AJXContainerView(73w) < AJXContainerView(73w) < AJXContainerView(390w 整行) < …
    //      → 若一味取最外层，关掉「我的反馈」会连同一行其它 3 个条目一起端掉，属于误伤。
    //    所以改成**两级择优**：
    //      · 一级：最外层「窄容器」（宽度 ≤ 屏 60%）—— 宫格里的单个条目、抽屉里的窄行，
    //              这正是「一个完整条目」的正确粒度；
    //      · 二级：一级找不到时，才退到最外层「矮容器」（满宽但高度 ≤ 屏高 50%）——
    //              整行 / 卡片；
    //      · 整页容器满宽 + 满高，两级都不满足，永远不会被端掉。
    UIView *cur = start;
    UIView *bestNarrow = nil;   // 一级：最外层窄容器
    UIView *bestShort = nil;    // 二级：最外层矮容器
    for (NSUInteger i = 0U; i < 8U && cur != nil; i++) {
        NSString *cn = NSStringFromClass(cur.class);
        CGFloat w = CGRectGetWidth(cur.bounds);
        CGFloat h = CGRectGetHeight(cur.bounds);

        BOOL hitPat = NO;
        for (NSString *p in pats) {
            if ([cn containsString:p]) { hitPat = YES; break; }
        }
        // AJX 自绘容器（高德「我的」页 / 抽屉 / 浮层）：文案只在 accessibilityLabel，
        // 容器类是 AJXContainerView / AJXWINView / WINAJXCombined*。
        BOOL hitAJX = ([cn containsString:@"AJXContainerView"] ||
                       [cn containsString:@"AJXWINView"] ||
                       [cn containsString:@"WINAJXCombinedItemView"] ||
                       [cn containsString:@"WINAJXCombinedWidgetView"]);
        BOOL isCell = ([cur isKindOfClass:[UICollectionViewCell class]] ||
                       [cur isKindOfClass:[UITableViewCell class]]);
        BOOL isNarrowCtrl = ([cur isKindOfClass:[UIControl class]] &&
                             w > 0.0 && w <= maxW);

        if (hitPat || hitAJX || isCell || isNarrowCtrl) {
            if (w > 0.0 && w <= maxW) {
                bestNarrow = cur;            // 一级命中
            } else if (h > 0.0 && h <= maxH) {
                bestShort = cur;             // 二级命中
            }
        }
        cur = cur.superview;
    }
    return bestNarrow ? bestNarrow : bestShort;
}

// 诊断用：把命中视图向上 6 层的「类名(宽x高)」链打出来，便于确认 AJX 容器的真实粒度，
// 下次日志据此校准 makVictimContainer 的两级择优阈值。
// （原来只打 4 层且只有宽度 —— 第十三轮日志里「我的」页宫格最外层是 390w 的整行，
//   4 层刚好卡在看不到父容器高度的地方，无法判断该藏条目还是整行。）
static NSString *makChain(UIView *v) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    UIView *c = v;
    for (NSUInteger i = 0U; i < 6U && c != nil; i++) {
        CGRect b = c.bounds;
        [a addObject:[NSString stringWithFormat:@"%@(%.0fx%.0f)",
                      NSStringFromClass(c.class),
                      (double)CGRectGetWidth(b), (double)CGRectGetHeight(b)]];
        c = c.superview;
    }
    return [a componentsJoinedByString:@" < "];
}

// 真正把视图「去干净」：
//   · 单元格（UICollectionViewCell / UITableViewCell）**只 hidden** —— 会被回收复用，
//     硬摘会引发布局错乱甚至崩溃（历史教训，别改回 remove）。
//   · 其余视图在 hidden 之外再 removeFromSuperview —— 只 hidden 的话 Auto Layout
//     仍按原约束给它留着位置，用户看到的就是「名字没了，占位还杵在那儿」。
static void makHideVictim(UIView *v) {
    if (v == nil) return;
    v.hidden = YES;
    // 下面这些「只 hidden、不摘」：它们是被父视图 / 数据源强持有的，硬摘会崩或错乱。
    if ([v isKindOfClass:[UICollectionViewCell class]] ||   // 列表 / 宫格 cell：回收复用
        [v isKindOfClass:[UITableViewCell class]] ||
        [v isKindOfClass:[UIScrollView class]] ||           // 滚动容器（含 AJXScrollView）
        [v isKindOfClass:[UIWindow class]] ||
        v.superview == nil) {
        return;
    }
    if (gGraveyard == nil) gGraveyard = [NSMutableSet set];
    [gGraveyard addObject:v];        // 先留住，再摘 —— 顺序不能反
    [v removeFromSuperview];
}

// 同一个「锚点 + 容器类」组合只打一条日志。
// 视图现在是**真摘掉**的，AJX 每次重排都可能重建出新的实例；2 秒一轮的轮询若每次都打印，
// 几分钟就能把日志冲到几 MB，反而看不清关键信息。首次出现打一条足够定位问题。
static BOOL makLogOnce(NSString *key) {
    static NSMutableSet<NSString *> *seen = nil;
    if (seen == nil) seen = [NSMutableSet set];
    if ([seen containsObject:key]) return NO;
    [seen addObject:key];
    return YES;
}

static void sweepUIItems(UIView *root) {
    if (root == nil) return;
    if (!bidIsAmap(NSBundle.mainBundle.bundleIdentifier)) return;  // 只做有数据的目标
    if (gUIHiddenAnchors.count == 0U && gUIHiddenClasses.count == 0U) return;  // 全显示 -> 早退

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0U;
    // 上限 4000 太容易截断：高德「我的」页是 AJX 自绘，光这一页的视图量就可能过千，
    // 加上首页浮层 / 信息流，一次遍历轻松破 4000 —— 被截断的子树就等于「没隐藏」。
    // 放宽到 30000，单次遍历仍是微秒级（只做 isa + 字符串比较，无 IO）。
    while (stack.count > 0U && guard++ < 30000U) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.isHidden) continue;            // 已经藏过的（上一轮补扫）直接跳过，开销可忽略
        NSString *cn = NSStringFromClass(v.class);

        // (1) 类名锚点：整块容器直接隐藏，优先级高于文案
        if ([gUIHiddenClasses containsObject:cn]) {
            if (makLogOnce([@"C|" stringByAppendingString:cn])) {
                MAKLog(@"UI HIDE class=%@ w=%.0f", cn, (double)CGRectGetWidth(v.bounds));
            }
            makHideVictim(v);
            continue;
        }

        // (2) 文案锚点：精确匹配后向上找**最外层**可藏容器（藏整块，而不是只藏名字）
        NSString *hit = makMatchedAnchor(v);
        if (hit) {
            UIView *victim = makVictimContainer(v);
            if (victim) {
                NSString *vk = NSStringFromClass(victim.class);
                if (makLogOnce([NSString stringWithFormat:@"T|%@|%@", hit, vk])) {
                    MAKLog(@"UI HIDE anchor=%@ victim=%@ w=%.0f h=%.0f chain=%@",
                           hit, vk,
                           (double)CGRectGetWidth(victim.bounds),
                           (double)CGRectGetHeight(victim.bounds), makChain(v));
                }
                makHideVictim(victim);
            } else {
                if (makLogOnce([NSString stringWithFormat:@"S|%@|%@", hit, cn])) {
                    MAKLog(@"UI SKIP anchor=%@ text=%@ (未找到容器，保守不藏) chain=%@",
                           hit, cn, makChain(v));
                }
            }
            continue;   // 已处理，不再下钻该子树
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
}

// 注：sweepUIItemsLater() 定义在 makSniff() 之后（要用到它），见下方。

// ---------------------------------------------------------------------------
// 文案嗅探（DebugLog 打开时才跑）
//
// 背景：早期日志里 5 个已关闭项的锚点一个都没命中（0 条 UI HIDE / UI SKIP），一度怀疑
// 高德首页是 AJX 自绘、原生 UILabel 树里没文案。加上这层嗅探后真相大白 ——
// 真机 UI TXT 直接吐出了：我的 | 打车 | 消息 | 附近 | 首页 | 扫一扫 | 语音输入 |
// 查找地点、公交、地铁 | 去设置 | 去单位 | 回家 | 更多工具 | 代驾 | 实时公交 |
// 顺风车 | 火车票机票 | 订酒店 | 优惠加油 | 公交 | 驾车 | 路线 | 更多 | 图层 | 我的位置
// 也就是说：**文案全在原生 UILabel 上，问题出在锚点表本身写错了**
// （安卓的「探索/长按说话/火车票」在 iOS 上叫「附近/语音输入/火车票机票」），
// 以及容器判定写错了（只认 TabBarButton，高德实际是 WINTabBarItem）。
// 两处都已在 re/gen_ui.py 与 makVictimContainer 里按真机数据修好。
//
// 这层嗅探留着继续用：还剩「我的」页和信息流 15 项没锚点，
// 开 DebugLog 翻一遍那两个页面，把 UI TXT 行发回来即可直接回填。
//
// 去重：每条文案 / 每个类名只记一次，不会刷屏。
// ---------------------------------------------------------------------------
static void makSniff(UIView *root, NSString *where) {
    if (!gDebugLog || root == nil) return;
    if (!bidIsAmap(NSBundle.mainBundle.bundleIdentifier)) return;

    static NSMutableSet<NSString *> *seenText  = nil;
    static NSMutableSet<NSString *> *seenClass = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seenText  = [NSMutableSet set];
        seenClass = [NSMutableSet set];
    });

    NSMutableArray<NSString *> *texts  = [NSMutableArray array];
    NSMutableArray<NSString *> *clsSet = [NSMutableArray array];
    // 第十六轮新增：光有文案还不够 —— 第十五轮日志里信息流那批文案（同城跑腿秒送达 /
    // 取送东西选秒送 / 接车保镖 现已上线 …）反复被嗅探到，却既没命中也没 SKIP，
    // 因为**它们所在容器的类名我们一个都不知道**，没法做成抗轮换的 uic_* 整块锚点。
    // 所以每条新文案连它自己的 3 层视图链一起打出来，下轮日志据此直接回填类名锚点。
    NSMutableArray<NSString *> *chains = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0U;
    while (stack.count > 0U && guard++ < 3000U) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        NSString *cn = NSStringFromClass(v.class);
        if (cn.length > 0U && ![seenClass containsObject:cn]) {
            [seenClass addObject:cn];
            if (clsSet.count < 40U) [clsSet addObject:cn];
        }

        NSString *t = nil;
        if ([v isKindOfClass:[UILabel class]]) {
            t = ((UILabel *)v).text;
        } else if ([v isKindOfClass:[UIButton class]]) {
            t = [((UIButton *)v) titleForState:UIControlStateNormal];
        }
        if (t.length == 0U) t = v.accessibilityLabel;
        if (t.length > 0U && t.length <= MAK_TXT_MAX) {
            NSString *s = [t stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (s.length > 0U && ![seenText containsObject:s]) {
                [seenText addObject:s];
                if (texts.count < 60U) [texts addObject:s];
                if (chains.count < 40U) {
                    NSMutableArray<NSString *> *cs = [NSMutableArray array];
                    UIView *p = v;
                    for (NSUInteger k = 0U; k < 3U && p != nil; k++) {
                        CGRect b = p.bounds;
                        [cs addObject:[NSString stringWithFormat:@"%@(%.0fx%.0f)",
                                       NSStringFromClass(p.class),
                                       (double)CGRectGetWidth(b), (double)CGRectGetHeight(b)]];
                        p = p.superview;
                    }
                    [chains addObject:[NSString stringWithFormat:@"%@ @ %@", s,
                                       [cs componentsJoinedByString:@" < "]]];
                }
            }
        }
        for (UIView *sv in v.subviews) [stack addObject:sv];
    }
    if (clsSet.count > 0U) {
        MAKLog(@"UI CLS %@ (%lu): %@", where, (unsigned long)clsSet.count,
               [clsSet componentsJoinedByString:@" | "]);
    }
    if (texts.count > 0U) {
        MAKLog(@"UI TXT %@ (%lu): %@", where, (unsigned long)texts.count,
               [texts componentsJoinedByString:@" | "]);
    }
    if (chains.count > 0U) {
        MAKLog(@"UI CHAIN %@ (%lu): %@", where, (unsigned long)chains.count,
               [chains componentsJoinedByString:@"\n    "]);
    }
}

// 多轮补扫：
// 真机日志证实工具宫格的条目是**服务端下发**的（上一版日志还是「实时公交」，下一版就变成
// 「秒送」），而网络数据往往在首帧之后才回到。只在 0.3s 那一帧扫一次会漏掉后加载的条目，
// 所以按 0.3 / 1.6 / 4.0 秒补三轮。已经藏过的视图会被 sweepUIItems 里的 isHidden 短路跳过，
// 重复开销量可以忽略。
static void sweepUIItemsLater(UIView *root, NSString *where) {
    static const NSTimeInterval kDelays[] = { 0.3, 1.6, 4.0 };
    for (NSUInteger i = 0U; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (root == nil || root.window == nil) return;  // VC 已经不在界面上了，别动它的 view
            makSniff(root, where);
            sweepUIItems(root);             // Layer 4 逐项去留：独立于 ViewSweep 开关
            if (!gViewSweep) return;        // Layer 1 清扫层：受 ViewSweep 控制
            sweepView(root);
        });
    }
}

// 轮询兜底用的 window。
//
// ⚠️ 真机校准（2026-09-22 第十六轮）：原来只留**最后一个** didMoveToWindow 报上来的 window
//    （gPollWindow），可第十五轮日志里出现了
//      UI CLS POLL (3): UIWindow | UITransitionView | UIDropShadowView
//    —— 一个只有 3 个类的**空壳 window**（浮层 / 弹窗容器）把主 window 顶掉了。
//    那一轮轮询扫的就是这个空壳，等于白扫：挂在主 window 上的信息流、我的页全漏掉，
//    而且表现为「既不 UI HIDE 也不 UI SKIP」，在日志里看不出任何异常。
//    现在改成**记住所有见过的 window**（弱引用，window 释放后自动消失），
//    轮询时对每一个都扫；嗅探只对面积最大的那个做，免得日志被小浮层刷爆。
static NSHashTable<UIWindow *> *gSeenWindows = nil;
static UIWindow *gPollWindow = nil;   // 保留给 DidBecomeActive 等处做单点补扫

static void makRememberWindow(UIWindow *w) {
    if (w == nil) return;
    if (gSeenWindows == nil) gSeenWindows = [NSHashTable weakObjectsHashTable];
    [gSeenWindows addObject:w];
    gPollWindow = w;
}

// 对所有见过的 window 做一遍清扫。回前台重读偏好后也要走这条 ——
// 只扫 gPollWindow 的话，若它恰好是那个空壳浮层 window，用户翻完开关依然「没反应」。
static void makSweepAllWindows(BOOL withLayer1) {
    if (gSeenWindows == nil) return;
    for (UIWindow *w in gSeenWindows.allObjects) {   // 先快照，避免遍历中被改
        if (![w isKindOfClass:[UIWindow class]]) continue;
        sweepUIItems(w);                             // Layer 4 逐项去留，独立于 ViewSweep
        if (withLayer1 && gViewSweep) sweepView(w);  // Layer 1 清扫层，受 ViewSweep 控制
    }
}

static void makPollOnce(void) {
    if (gSeenWindows == nil) return;
    UIWindow *biggest = nil;
    CGFloat bestArea = 0.0;
    for (UIWindow *w in gSeenWindows.allObjects) {
        if (![w isKindOfClass:[UIWindow class]]) continue;
        CGRect b = w.bounds;
        CGFloat area = CGRectGetWidth(b) * CGRectGetHeight(b);
        if (area > bestArea) { bestArea = area; biggest = w; }
    }
    makSweepAllWindows(YES);
    makSniff(biggest, @"POLL");   // 内部按 seenText/seenClass 全局去重，稳态不会刷屏
}

// 为什么需要轮询（真机第十二轮证实）：
// AJX 这类自绘引擎很可能**在已有视图上原地改内容**，压根不挂载新视图 ——
// 那样 viewDidAppear（新 VC）和 didMoveToWindow（新视图）**两个事件都不会触发**，
// 单靠事件驱动永远抓不到「我的」这种页面。只能定时轮询兜底。
// 用 dispatch_after 自递归续期，省掉 timer 对象的生命周期管理；
// makSniff 全局去重，界面不变时不会产生任何日志。
static void makPollSchedule(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        makPollOnce();
        makPollSchedule();
    });
}

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *vc = self;
    NSString *where = NSStringFromClass(vc.class);
    if (vc.view.window != nil) {
        makRememberWindow(vc.view.window);
        static dispatch_once_t pollOnce;
        dispatch_once(&pollOnce, ^{ makPollSchedule(); });
    }
    sweepUIItemsLater(vc.view, where);
}
%end

// ⚠️ 真机前十轮日志的教训：只靠 UIViewController 的 viewDidAppear 触发是不够的。
// 高德底部「我的」tab 是**在同一个容器 VC（AMNavigationController）里换子视图**渲染的
// （AJX 自绘，和「我的」抽屉同源），并不会有新的 UIViewController 出现 ——
// 于是 viewDidAppear 永远不触发，那 5 个「我的」页锚点连一次 UI TXT 都抓不到，
// 尽管用户每次都停在那儿。
// 而且这不只是调试问题：sweepUIItems 也挂在同一个触发点上，意味着将来锚点填好了，
// 在「我的」页同样不会生效。
// 对策：改由「有视图被挂进 window」驱动，并做节流，避免滚动时每个子视图都触发一次。
%hook UIView
- (void)didMoveToWindow {
    %orig;
    UIWindow *w = self.window;
    if (w == nil) return;
    makRememberWindow(w);
    static dispatch_once_t pollOnce;
    dispatch_once(&pollOnce, ^{ makPollSchedule(); });
    static NSTimeInterval lastAt = 0.0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastAt < 2.0) return;   // 节流 2 秒，滚动时不会每个子视图都排一轮补扫
    lastAt = now;
    sweepUIItemsLater(w, NSStringFromClass(self.class));
}
%end

#pragma mark - Layer 2: 广告 SDK 运行时自动拦截（Android SdkAutoBlock 等价）

#pragma mark - 闸门 4：展示闸门保护（Aggressive 关时才生效）
//
// 真机日志暴露的问题：Layer 2 扫到 WINSplashScreenPresenter 时，把
//   presentRealTimeSplashScreen:scene:...: / addSplashViewForResource:creative:sessionId:
//   downloadSplashScreenAssets:scene:completionBlock: / asyncIsLocalSplashDataCanExposure:
// 这些都 no-op 了 —— 而这批方法恰恰是 Layer 3 激进层里「默认关、会卡启动页」的那几个。
// 结果就是：用户没开 Aggressive，激进层的风险却已经由 Layer 2 替他承担了，
// 「激进层默认关」这个闸门形同虚设。
//
// 所以 Layer 2 也必须遵守同一条纪律：没开 Aggressive 时，凡是有这些特征的一律让开：
//   present*          展示闸门（App 可能在等开屏结束的回调，no-op 会卡在启动页）
//   *completionBlock: 带 block 的异步方法（回调链断裂）
//   async*            同上
//   add*View*         往视图树上挂开屏 View 的入口
static BOOL makRiskySelector(NSString *selName) {
    if (selName.length == 0U) return NO;
    if ([selName hasPrefix:@"present"] || [selName hasPrefix:@"Present"]) return YES;
    if ([selName hasPrefix:@"async"]   || [selName hasPrefix:@"Async"])   return YES;
    if ([selName rangeOfString:@"completion" options:NSCaseInsensitiveSearch]
        .location != NSNotFound) return YES;
    if ([selName hasPrefix:@"add"] &&
        [selName rangeOfString:@"View"].location != NSNotFound) return YES;
    return NO;
}

static void blockAdSDKs(void) {
    if (!gSdkBlock) return;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    int got = objc_getClassList(classes, count);
    int scannedClasses = 0;
    int blockedClasses = 0;
    int hookedMethods = 0;
    int skippedSystem = 0;
    int riskySkipped = 0;
    NSString *appPrefix = makAppPathPrefix();
    MAKLog(@"SDK block scan: classes=%d appPath=%@", got, appPrefix ?: @"(nil)");
    for (int i = 0; i < got; i++) {
        Class c = classes[i];
        NSString *cname = NSStringFromClass(c);
        if (!adNameMatch(cname)) continue;
        if (!makClassAllowed(c)) {                 // 闸门 1：系统框架类一律放行
            skippedSystem++;
            MAKLog(@"SDK SKIP(sys) %@ img=%s", cname,
                   class_getImageName(c) ?: "(null)");
            continue;
        }
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(c, &mcount);
        if (!methods) continue;
        BOOL touchedThisClass = NO;
        for (unsigned int j = 0; j < mcount; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(sel);
            if (!isAdSelector(selName)) continue;
            // 闸门 4：没开激进层时，展示闸门 / 带 block 的异步方法必须让开
            if (!gAggressive && makRiskySelector(selName)) {
                riskySkipped++;
                MAKLog(@"SDK SKIP(risky) %@ %@", cname, selName);
                continue;
            }
            method_setImplementation(methods[j], (IMP)adNoOp);
            hookedMethods++;
            touchedThisClass = YES;
            MAKLog(@"SDK BLOCK %@ %@", cname, selName);
        }
        free(methods);
        if (mcount > 0) scannedClasses++;
        if (touchedThisClass) blockedClasses++;
    }
    free(classes);
    MAKNote(@"SDK block done: scanned=%d blockedClasses=%d methods=%d "
            @"skippedSystem=%d skippedRisky=%d",
            scannedClasses, blockedClasses, hookedMethods, skippedSystem, riskySkipped);
}

#pragma mark - Layer 3: 定点 hook
//
// 数据来源：高德地图 15.03.0 砸壳 IPA 静态解析
//   python3 re/ipa_dump.py 高德地图_15.03.0.ipa --frameworks --objc
// 源码: re/ipa_dump.py / 结果: re/amap_15.03.0_dump.txt
//
// 分两层，跟 Android 版 ViewKiller「宁可少杀不可杀错」的原则一致：
//   安全层 (SAFE)     —— 只断「数据 + 素材 + 标识」，让 App 自己判定"没有开屏广告"。
//                        挑的都是无 completionBlock 参数的方法：no-op 后不会卡住任何回调链。
//   激进层 (AGGRESSIVE)—— 直接 no-op 展示闸门 / 带 block 的异步方法。
//                        效果最狠，但 present 系列若被 App 用来等待开屏结束，可能卡在启动页。
//                        默认关，用 DebugLog 观察安全层效果不够时再单独打开。
//
// ⚠️ 混淆漂移：15.03.0 之外的大版本类名可能变化。所有 hook 都是 miss 即跳过（fail-open），
//    失效只表现为"又开始出广告"，不会崩 App。升级后重跑一次 ipa_dump.py 即可。

static NSArray<NSArray<NSString *> *> *amapSafeHooks(void) {
    return @[
        // ---- 开屏：数据可用性判定 ----
        @[@"WINSplashScreenVAppService",        @"fetchSplashDataWithScene:"],
        @[@"WINSplashScreenVAppService",        @"isLocalSplashDataCanExposure"],
        @[@"WINSplashScreenDataPersistentWorker", @"querySplashData"],
        @[@"WINSplashScreenDataPersistentWorker", @"splashData"],
        @[@"WINSplashScreenDataPersistentWorker", @"setSplashData:"],
        @[@"WINSplashScreenDataPersistentWorker", @"setSplashDataCache:"],
        @[@"WINSplashScreenData",               @"ad"],
        @[@"WINSplashScreenData",               @"setAd:"],
        @[@"WINSplashScreenData",               @"containsAliMotherAd"],

        // ---- 开屏：附属视图 / 交互引导 ----
        @[@"WINSplashView",                     @"showSplashAccessories"],
        @[@"WINSplashRollView",                 @"processRollSplashGuideWithProgress:"],
        @[@"WINSplashFullScreenSlideAndTapInteractionView",
                                                @"processRollSplashGuideWithProgress:"],

        // ---- 广告标识 ----
        @[@"WINADView",                         @"setAdLabel:"],
        @[@"WINADView",                         @"refreshADLabel:"],

        // ---- Banner ----
        @[@"AMAOSBannerListData",               @"bannerInfo"],
        @[@"AMAOSBannerListData",               @"setBannerInfo:"],
        @[@"WINTrainPicBannerView",             @"bannerView"],
        @[@"WINTrainPicBannerView",             @"setBannerView:"]
    ];
}

static NSArray<NSArray<NSString *> *> *amapAggressiveHooks(void) {
    return @[
        // ---- 开屏闸门（直接掐展示，效果最狠） ----
        @[@"WINSplashScreenPresenter", @"presentSplashScreenWithData:scene:fromBackground:otherInfo:filteringSuccessBlock:filteringFailureBlock:playFinishBlock:animationFinishBlock:"],
        @[@"WINSplashScreenPresenter", @"presentRealTimeSplashScreen:scene:filteringSuccessBlock:filteringFailureBlock:playFinishBlock:animationFinishBlock:"],
        @[@"WINSplashScreenPresenter", @"addSplashViewForResource:creative:sessionId:"],
        @[@"WINSplashScreenPresenter", @"setSplashView:"],

        // ---- 带 completionBlock 的异步方法（有卡回调链风险） ----
        @[@"WINSplashScreenVAppService",          @"doFetchSplashDataAfterDelay:scene:isExposeScene:completionBlock:"],
        @[@"WINSplashScreenVAppService",          @"fetchSplashDataAfterDelay:scene:isExposeScene:completionBlock:"],
        @[@"WINSplashScreenVAppService",          @"saveSplashDataAndStartDownloadAssets:scene:completionBlock:"],
        @[@"WINSplashScreenVAppService",          @"asyncHasLocalSplashDataInToday:"],
        @[@"WINSplashScreenVAppService",          @"asyncIsLocalSplashDataCanExposure:"],
        @[@"WINSplashScreenDataPersistentWorker", @"asyncQuerySplashData:"],
        @[@"WINSplashScreenAssetsDownloader",     @"downloadSplashScreenAssets:scene:completionBlock:"],

        // ---- 开屏 view 构建 ----
        @[@"LTMAJX3SplashView",                   @"loadViewWithConfig:"]
    ];
}

static void installTargetedHooks(NSString *bundleID) {
    NSArray<NSArray<NSString *> *> *hooks = nil;

    if (bidIsAmap(bundleID)) {
        hooks = amapSafeHooks();
        if (gAggressive) {
            hooks = [hooks arrayByAddingObjectsFromArray:amapAggressiveHooks()];
            MAKNote(@"amap: 激进层已启用 (Aggressive=YES)");
        }
    } else if ([bundleID isEqualToString:kTargetBmap]) {
        hooks = @[ /* 百度：待用 ipa_dump.py 解析其砸壳包后填充 */ ];
    } else if ([bundleID isEqualToString:kTargetTmap]) {
        hooks = @[ /* 腾讯：待用 ipa_dump.py 解析其砸壳包后填充 */ ];
    }

    if (!hooks) return;
    int ok = 0, miss = 0;
    for (NSArray<NSString *> *pair in hooks) {
        if (pair.count < 2U) continue;
        Class c = objc_getClass([pair[0] UTF8String]);
        SEL s = NSSelectorFromString(pair[1]);
        if (!c || !s) { MAKLog(@"targeted MISS %@ %@", pair[0], pair[1]); miss++; continue; }
        noOpMethod(c, s);
        ok++;
    }
    MAKNote(@"targeted hooks: ok=%d miss=%d (版本漂移会体现为 miss)", ok, miss);
}

#pragma mark - Entry

%ctor {
    gPrefs_load();

    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    BOOL isTarget = bidIsAmap(bid) ||
                    [bid isEqualToString:kTargetBmap] ||
                    [bid isEqualToString:kTargetTmap];
    if (!gEnabled || !isTarget) {
        MAKNote(@"skip (enabled=%d target=%@)", gEnabled, bid);
        return;
    }
    // 仅对启用的目标 App 安装
    if ((bidIsAmap(bid) && !gAmap) ||
        ([bid isEqualToString:kTargetBmap] && !gBmap) ||
        ([bid isEqualToString:kTargetTmap] && !gTmap)) {
        MAKNote(@"app disabled %@", bid);
        return;
    }

    MAKNote(@"loaded for %@ | build=%@ | enabled sweep=%d sdk=%d aggressive=%d",
          bid, MAK_BUILD_TAG, gViewSweep, gSdkBlock, gAggressive);

    // Layer 2：广告 SDK 自动拦截（进程内一次性）
    blockAdSDKs();

    // Layer 3：定点 hook（placeholder，RE 后填）
    installTargetedHooks(bid);

    // Layer 1：UIView 清扫（UIViewController hook 已全局挂载，仅本进程生效）
    // 应用切前台时也扫一次 keyWindow（覆盖非 VC 绑定的开屏/弹窗）
    (void)[[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *__unused note) {
                    // 关键：回到前台必须重读偏好。
                    // 偏好原本只在注入那一刻读一次，于是「设置里翻开关 → 切回高德」时
                    // 只要 App 没被杀就完全不生效 —— 用户反馈的「怎么隐藏都没效果」正是这个。
                    gPrefs_load();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (gViewSweep) sweepKeyWindow();
                        // Layer 4 逐项去留独立于 ViewSweep，重读后要立刻把新结果应用到界面
                        makSweepAllWindows(NO);   // 所有 window 都扫，不能只扫 gPollWindow
                    });
                }];

    // 文件日志：启动时先落一次盘（保证 loaded for / ui items 这类关键行立刻可见），
    // 进后台时再落一次，避免缓冲里最后几行被丢掉。
    if (gFileLog) {
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *__unused note) { makLogFlush(); }];
        makLogFlush();
    }
}
