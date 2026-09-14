ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = APlayer

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = APlayerAudioProbe
APlayerAudioProbe_FILES = Tweak.xm
APlayerAudioProbe_CFLAGS = -fobjc-arc -O2
APlayerAudioProbe_CCFLAGS = -O2
APlayerAudioProbe_FRAMEWORKS = Foundation UIKit AVFoundation AudioToolbox AudioUnit
APlayerAudioProbe_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
