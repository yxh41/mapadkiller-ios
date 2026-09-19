include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MapAdKillerSettings

MapAdKillerSettings_FILES = MapAdKillerSettingsController.m
MapAdKillerSettings_INSTALL_PATH = /Library/PreferenceBundles
MapAdKillerSettings_FRAMEWORKS = UIKit
MapAdKillerSettings_PRIVATE_FRAMEWORKS = Preferences
MapAdKillerSettings_RESOURCES = Resources/Root.plist
# 显式指定 Info.plist（设了 RESOURCES 后 bundle.mk 不再自动生成，必须指明，
# 否则 .bundle 里没有 NSPrincipalClass，设置页打不开）
MapAdKillerSettings_INFOPLIST_PATH = MapAdKillerSettings.plist
MapAdKillerSettings_CFLAGS = -fobjc-arc -Werror

include $(THEOS_MAKE_PATH)/bundle.mk
