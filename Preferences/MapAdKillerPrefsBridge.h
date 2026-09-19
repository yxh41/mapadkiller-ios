//
//  MapAdKillerPrefsBridge.h
//  跨 App 偏好桥：roothide 下 NSUserDefaults(suiteName:) 的【手动写入】会落到「设置」App 自身的
//  容器副本，tweak 注入到地图 App 时读不到。本桥直接读写 PreferenceLoader 写入的全局 plist 文件，
//  绕过 per-app 容器化，确保「设置」写入与「tweak」读取命中同一物理文件。
//  （范式取自 yxh41/Oback 的 ObackPrefsBridge.h，已在其 roothide/iOS16.4.1 环境验证。）
//  函数体为 static inline（ARC 安全），tweak 与设置 bundle 各自编一份、互不影响。
//

#import <Foundation/Foundation.h>

static NSString *const kMAKGlobalPlist = @"/var/mobile/Library/Preferences/com.yxh41.mapadkiller.plist";

// 读取全局偏好字典（文件不存在时返回空字典，调用方须判空）
static inline NSDictionary *mak_globalPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kMAKGlobalPlist];
    return d ? d : @{};
}

// 写入单个 key（value 为 nil 表示删除）
static inline void mak_setGlobalPref(NSString *key, id value) {
    if (!key) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kMAKGlobalPlist];
    if (!d) d = [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:kMAKGlobalPlist atomically:YES];
}
