include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MapAdKillerSettings

MapAdKillerSettings_FILES = MapAdKillerSettingsController.m
MapAdKillerSettings_INSTALL_PATH = /Library/PreferenceBundles
MapAdKillerSettings_FRAMEWORKS = UIKit
MapAdKillerSettings_PRIVATE_FRAMEWORKS = Preferences
MapAdKillerSettings_RESOURCES = Resources/Root.plist
# Info.plist（含 NSPrincipalClass）通过 layout/ 直装到 .bundle 根，避免依赖
# roothide theos bundle.mk 的 INFOPLIST_PATH 机制（不可靠，曾导致缺失）
MapAdKillerSettings_CFLAGS = -fobjc-arc -Werror

include $(THEOS_MAKE_PATH)/bundle.mk
