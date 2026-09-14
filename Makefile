ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = Bilibili

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlobalTimePitchFix
ST_SRC = \
	vendor/soundtouch/source/SoundTouch/AAFilter.cpp \
	vendor/soundtouch/source/SoundTouch/FIRFilter.cpp \
	vendor/soundtouch/source/SoundTouch/FIFOSampleBuffer.cpp \
	vendor/soundtouch/source/SoundTouch/RateTransposer.cpp \
	vendor/soundtouch/source/SoundTouch/SoundTouch.cpp \
	vendor/soundtouch/source/SoundTouch/TDStretch.cpp \
	vendor/soundtouch/source/SoundTouch/InterpolateLinear.cpp \
	vendor/soundtouch/source/SoundTouch/InterpolateCubic.cpp \
	vendor/soundtouch/source/SoundTouch/InterpolateShannon.cpp
GlobalTimePitchFix_FILES = Tweak.xm $(ST_SRC)
GlobalTimePitchFix_CFLAGS = -fobjc-arc -O3 -DANDROID=1 -DSOUNDTOUCH_FLOAT_SAMPLES=1 -DSOUNDTOUCH_DISABLE_X86_OPTIMIZATIONS=1 -Ivendor/soundtouch/include -Ivendor/soundtouch/source/SoundTouch
GlobalTimePitchFix_CCFLAGS = -O3 -DANDROID=1 -DSOUNDTOUCH_FLOAT_SAMPLES=1 -DSOUNDTOUCH_DISABLE_X86_OPTIMIZATIONS=1 -Ivendor/soundtouch/include -Ivendor/soundtouch/source/SoundTouch
GlobalTimePitchFix_LDFLAGS = -lm
GlobalTimePitchFix_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
