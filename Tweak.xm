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
static BOOL gDebugLog   = NO;   // 调试日志
static BOOL gAmap       = YES;
static BOOL gBmap       = YES;
static BOOL gTmap       = YES;

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
    gAmap       = makBool(d, @"Amap",       gAmap);
    gBmap       = makBool(d, @"Bmap",       gBmap);
    gTmap       = makBool(d, @"Tmap",       gTmap);
}
static void MAKLog(NSString *fmt, ...) {
    if (!gDebugLog) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[MapAdKiller] %@", msg);
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

static NSSet<NSString *> *makAdTokens(void) {
    static NSSet<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"ad", @"ads", @"advert", @"splash", @"banner", @"interstitial",
            @"reward", @"promo", @"popup", @"popupad", @"nativead",
            @"adview", @"adslot", @"adkit", @"admanager", @"adloader",
            @"addata", @"admodel", @"adconfig", @"adservice", @"adrequest",
            @"adresponse", @"adsdk", @"adx", @"adz", @"adunion", @"adprovider",
            @"adbanner", @"adsplash", @"adresource", @"admaterial", @"adtrack"
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
            @"taku", @"adscope", @"klevin", @"advertis", @"interstitial",
            @"rewardvideo"
        ];
    });
    return s;
}

// 单个驼峰段是否本身是广告词（含厂商名 / 词根）
static BOOL segIsAdToken(NSString *seg) {
    NSString *low = seg.lowercaseString;
    if ([makAdTokens() containsObject:low]) return YES;
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
    if ([nm hasPrefix:@"UI"] || [nm hasPrefix:@"NS"] || [nm hasPrefix:@"CA"] ||
        [nm hasPrefix:@"CG"] || [nm hasPrefix:@"WK"] || [nm hasPrefix:@"MK"] ||
        [nm hasPrefix:@"CL"] || [nm hasPrefix:@"AV"] || [nm hasPrefix:@"CT"] ||
        [nm hasPrefix:@"CF"] || [nm hasPrefix:@"SK"] || [nm hasPrefix:@"PH"]) {
        return NO;
    }
    NSArray<NSString *> *segs = makCamelSegs(nm);
    for (NSString *sg in segs) {
        if (segIsAdToken(sg)) return YES;
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
        if (adNameMatch(cls)) hit = YES;
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

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!gViewSweep) return;
    UIViewController *vc = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (vc.view) sweepView(vc.view);
    });
}
%end

#pragma mark - Layer 2: 广告 SDK 运行时自动拦截（Android SdkAutoBlock 等价）

static void blockAdSDKs(void) {
    if (!gSdkBlock) return;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    int got = objc_getClassList(classes, count);
    int hookedClasses = 0;
    int hookedMethods = 0;
    for (int i = 0; i < got; i++) {
        Class c = classes[i];
        NSString *cname = NSStringFromClass(c);
        if (!adNameMatch(cname)) continue;
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(c, &mcount);
        if (!methods) continue;
        for (unsigned int j = 0; j < mcount; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(sel);
            if (isAdSelector(selName)) {
                method_setImplementation(methods[j], (IMP)adNoOp);
                hookedMethods++;
                MAKLog(@"SDK BLOCK %@ %@", cname, selName);
            }
        }
        free(methods);
        if (mcount > 0) hookedClasses++;
    }
    free(classes);
    NSLog(@"[MapAdKiller] SDK block done: classes=%d methods=%d", hookedClasses, hookedMethods);
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
            NSLog(@"[MapAdKiller] amap: 激进层已启用 (Aggressive=YES)");
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
    NSLog(@"[MapAdKiller] targeted hooks: ok=%d miss=%d (版本漂移会体现为 miss)", ok, miss);
}

#pragma mark - Entry

%ctor {
    gPrefs_load();

    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    BOOL isTarget = bidIsAmap(bid) ||
                    [bid isEqualToString:kTargetBmap] ||
                    [bid isEqualToString:kTargetTmap];
    if (!gEnabled || !isTarget) {
        NSLog(@"[MapAdKiller] skip (enabled=%d target=%@)", gEnabled, bid);
        return;
    }
    // 仅对启用的目标 App 安装
    if ((bidIsAmap(bid) && !gAmap) ||
        ([bid isEqualToString:kTargetBmap] && !gBmap) ||
        ([bid isEqualToString:kTargetTmap] && !gTmap)) {
        NSLog(@"[MapAdKiller] app disabled %@", bid);
        return;
    }

    NSLog(@"[MapAdKiller] loaded for %@ | build=%@ | enabled sweep=%d sdk=%d aggressive=%d",
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
                    if (!gViewSweep) return;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        sweepKeyWindow();
                    });
                }];
}
