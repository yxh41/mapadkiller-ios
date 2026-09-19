# MapAdKiller-iOS — Theos tweak (iOS 16, roothide, arm64/arm64e)
# 复刻 yxh41/MapAdKiller (Android Xposed) 到 iOS 越狱环境。
#
# 构建说明：
#   * 用 roothide 官方 theos 分支（roothide/theos）构建，它内置 roothide package
#     scheme；make package 直接产出 iphoneos-arm64e 的 roothide .deb，无需 patch.sh。
#     标准 theos/theos 没有 roothide scheme，不能用。
#   * ARCHS 编 arm64 + arm64e：真机 App Store App 走 arm64e，arm64 用于兼容验证。
#   * 不依赖 Cephei：roothide/theos 的 include/ 是空的，社区也没有 Cephei 的
#     roothide fork，CI 里编不过。设置面板走自写 PreferenceLoader bundle（见 Preferences/ 子工程，
#     仿 yxh41/Oback 的 ObackPrefsBridge 直写全局 plist，绕开 roothide per-app NSUserDefaults 容器隔离）。
#   * -Werror：沿用其它 tweak 的 CI 约定；请勿引入废弃 UIKit 调用
#     （UIApplication.keyWindow / windows / UI_USER_INTERFACE_IDIOM 一律不用）。

#   * 暂不挂 -Wall：本地无编译环境，先用 -Werror 拿到干净构建再去收紧，
#     避免 CI 反复往返。deprecation 警告默认开启，废弃 UIKit 仍会被拦下。

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

THEOS_PACKAGE_SCHEME := roothide
# 不要在这里写 PACKAGE_VERSION —— 它会覆盖 control 的 Version，
# 导致 CI 注入的 "0.0.1+<commit hash>" 失效。版本号以 control 为准。

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := MapAdKiller
MapAdKiller_FILES := Tweak.xm
MapAdKiller_FRAMEWORKS := UIKit Foundation
# mak_ui_items.h 是 re/gen_ui.py 生成的锚点表（与 Root.plist 同源）。
# Tweak.xm 被 logos 预处理后会写到 build 目录再交给 clang，届时 quoted include 是相对
# 「预处理产物所在目录」解析的，找不到源文件这一层 —— 所以必须显式把工程根目录挂进 -I。
MapAdKiller_CFLAGS := -fobjc-arc -Werror -I$(shell pwd)

include $(THEOS_MAKE_PATH)/tweak.mk

# 设置面板子工程（编译型 PreferenceLoader bundle，随 tweak 一起打进 roothide .deb）
SUBPROJECTS = Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	@echo "MapAdKiller: installed. Respring, then reopen the target map app."
	@killall -9 SpringBoard 2>/dev/null || true
