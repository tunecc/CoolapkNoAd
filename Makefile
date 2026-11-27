TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# 按越狱插件打包规范（官方原生 scheme）区分部署目标：
#   rootless 仅支持 iOS 15+；roothide / rootful 取 14.0
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KuAnNoAds
KuAnNoAds_FILES = Tweak.xm
KuAnNoAds_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-but-set-variable -Wno-deprecated-declarations -I. -Os $(EXTRA_CFLAGS)
KuAnNoAds_FRAMEWORKS = UIKit Foundation
KuAnNoAds_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
