//
//  MapAdKillerSettingsController.m
//  设置页主控制器 —— 由 Root.plist 描述所有开关，域统一为 com.yxh41.mapadkiller。
//  不依赖 Cephei：直接读写全局 plist 文件（见 MapAdKillerPrefsBridge.h），
//  与 Tweak.xm 的 gPrefs_load 命中同一物理文件，绕开 roothide per-app NSUserDefaults 容器隔离。
//

#import "MapAdKillerSettingsController.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import "MapAdKillerPrefsBridge.h"

// ⚠️ roothide 的 PSListController.h 未公开声明 setPreferenceValue:forSpecifier:，
// 但 PreferenceLoader 运行时确实实现该方法；补前向声明让 [super setPreferenceValue:...]
// 通过 -Werror 编译（否则报 "no visible @interface declares the selector"）。
@interface PSListController (MAKSetPrefForward)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
@end

// PSSpecifier 头未声明 setProperty:forKey:，补声明以直接调用（避免 performSelector 警告 -Werror 编译失败）
@interface PSSpecifier (MAKSetProp)
- (void)setProperty:(id)property forKey:(NSString *)key;
@end

@implementation MapAdKillerSettingsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// roothide 下 PSSwitchCell 的标准写入可能落到「设置」App 的 per-app 容器副本，
// 而 tweak 注入地图 App 时读的是全局 plist 文件。故每次变更都镜像写一份到全局文件，
// 确保「设置」与「tweak」命中同一物理文件。
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value forSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if (key) mak_setGlobalPref(key, value);
}

// 兜底镜像：打开设置页时把各开关当前值从 suite 同步到全局文件，
// 覆盖「setPreferenceValue: 不被调用」的 roothide 版本。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_specifiers) [self specifiers];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yxh41.mapadkiller"];
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (!key) continue;
        id val = [d objectForKey:key];
        if (val) mak_setGlobalPref(key, val);   // 仅镜像有显式值的 key；nil 跳过，避免清掉未设置项的默认
    }
}

@end
