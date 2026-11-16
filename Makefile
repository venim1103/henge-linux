# SPDX-License-Identifier: GPL-3.0-or-later
# henge-linux top-level build system (macOS Apple Silicon, macOS Intel x86_64, Linux)

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# Auto-detect Homebrew prefix (/opt/homebrew on Apple Silicon, /usr/local on Intel Mac)
BREW_PREFIX := $(shell if [ -d /opt/homebrew ]; then echo /opt/homebrew; elif [ -d /usr/local/Homebrew ] || [ -d /usr/local/Cellar ]; then echo /usr/local; fi)

# Stage-1 software TLB granularity:
#   12 = 4 KiB compatibility mode (boots both 4 KiB and 16 KiB Linux kernels)
#   14 = 16 KiB fast-path mode (4x TLB reach for CONFIG_ARM64_16K_PAGES=y kernels)
HV_TLB_PAGE_BITS ?= 12
REQUIRE_UPSTREAM ?= 0

CC ?= cc
CFLAGS_COMMON := -std=c11 -O2 -Wall -Wextra -Werror -DHV_TLB_PAGE_BITS=$(HV_TLB_PAGE_BITS) -Ihost

BUILD_DIR := build
UPSTREAM_DIR := .upstream/WindowsiOS

.PHONY: all clean test-core hvsparse ios-lib ios-lib-full sync-upstream ios-project

all: test-core hvsparse

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

HOST_SRCS := host/henge_platform.c host/henge_txm_jit.c host/henge_virtio_gpu.c
HOST_HDRS := host/henge_platform.h host/henge_txm_jit.h host/henge_virtio_gpu.h
HOST_ASM  := $(if $(filter aarch64 arm64,$(UNAME_M)),host/henge_brk.S,)

$(BUILD_DIR)/test_core: tests/test_core.c $(HOST_SRCS) $(HOST_HDRS) $(HOST_ASM) | $(BUILD_DIR)
	$(CC) $(CFLAGS_COMMON) -pthread tests/test_core.c $(HOST_SRCS) $(HOST_ASM) -o $(BUILD_DIR)/test_core

$(BUILD_DIR)/hvsparse: tools/hvsparse.c | $(BUILD_DIR)
	$(CC) $(CFLAGS_COMMON) tools/hvsparse.c -o $(BUILD_DIR)/hvsparse

hvsparse: $(BUILD_DIR)/hvsparse

test-core: $(BUILD_DIR)/test_core
	./$(BUILD_DIR)/test_core

UPSTREAM_CORE_SRCS := \
	$(UPSTREAM_DIR)/core/classify.c \
	$(UPSTREAM_DIR)/core/operands.c \
	$(UPSTREAM_DIR)/core/translate.c \
	$(UPSTREAM_DIR)/core/dispatch.c \
	$(UPSTREAM_DIR)/core/memop.c \
	$(UPSTREAM_DIR)/core/exception.c \
	$(UPSTREAM_DIR)/core/sysreg.c \
	$(UPSTREAM_DIR)/core/machine.c

UPSTREAM_HOST_SRCS := \
	$(UPSTREAM_DIR)/host/jit_region.c \
	$(UPSTREAM_DIR)/host/disk.c \
	$(UPSTREAM_DIR)/host/winvm.c \
	$(UPSTREAM_DIR)/host/net_slirp.c \
	$(UPSTREAM_DIR)/host/share.c \
	$(UPSTREAM_DIR)/host/audio_mac.c \
	$(UPSTREAM_DIR)/host/hvsparse.c

UPSTREAM_DEV_SRCS := \
	$(UPSTREAM_DIR)/devices/acpi.c \
	$(UPSTREAM_DIR)/devices/fb_display.c \
	$(UPSTREAM_DIR)/devices/fdt.c \
	$(UPSTREAM_DIR)/devices/fw_cfg.c \
	$(UPSTREAM_DIR)/devices/gicv3.c \
	$(UPSTREAM_DIR)/devices/hda.c \
	$(UPSTREAM_DIR)/devices/nvme.c \
	$(UPSTREAM_DIR)/devices/pcie.c \
	$(UPSTREAM_DIR)/devices/pflash.c \
	$(UPSTREAM_DIR)/devices/pl011.c \
	$(UPSTREAM_DIR)/devices/pl031.c \
	$(UPSTREAM_DIR)/devices/pl061.c \
	$(UPSTREAM_DIR)/devices/timer.c \
	$(UPSTREAM_DIR)/devices/virtio.c \
	$(UPSTREAM_DIR)/devices/virtio_blk.c \
	$(UPSTREAM_DIR)/devices/virtio_input.c \
	$(UPSTREAM_DIR)/devices/virtio_net.c \
	$(UPSTREAM_DIR)/devices/virtio_snd.c \
	$(UPSTREAM_DIR)/devices/winvirt.c \
	$(UPSTREAM_DIR)/devices/xhci.c

IOS_HOST_OBJS := \
	$(BUILD_DIR)/ios/henge_platform.o \
	$(BUILD_DIR)/ios/henge_txm_jit.o \
	$(BUILD_DIR)/ios/henge_brk.o \
	$(BUILD_DIR)/ios/henge_virtio_gpu.o

UPSTREAM_CORE_OBJS := $(patsubst $(UPSTREAM_DIR)/core/%.c,$(BUILD_DIR)/ios/up_core_%.o,$(UPSTREAM_CORE_SRCS))
UPSTREAM_HOST_OBJS := $(patsubst $(UPSTREAM_DIR)/host/%.c,$(BUILD_DIR)/ios/up_host_%.o,$(UPSTREAM_HOST_SRCS))
UPSTREAM_DEV_OBJS  := $(patsubst $(UPSTREAM_DIR)/devices/%.c,$(BUILD_DIR)/ios/up_dev_%.o,$(UPSTREAM_DEV_SRCS))
UPSTREAM_ALL_OBJS  := \
	$(BUILD_DIR)/ios/up_core_mmu.o \
	$(BUILD_DIR)/ios/up_host_enter.o \
	$(BUILD_DIR)/ios/up_dev_fb_metal.o \
	$(UPSTREAM_CORE_OBJS) \
	$(UPSTREAM_HOST_OBJS) \
	$(UPSTREAM_DEV_OBJS)

ifeq ($(UNAME_S),Darwin)
IOS_SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
IOS_BASE := -O2 -arch arm64 -mios-version-min=26.0 -isysroot $(IOS_SDK) -DHV_TLB_PAGE_BITS=$(HV_TLB_PAGE_BITS) -Ihost -Werror=implicit-function-declaration -Werror=incompatible-pointer-types
IOS_CFLAGS := -std=c11 -Wall -Wextra -Werror $(IOS_BASE)
IOS_UP_CFLAGS := -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-missing-field-initializers $(IOS_BASE)
ENG_INC := -I$(UPSTREAM_DIR)/core -I$(UPSTREAM_DIR)/host -I$(UPSTREAM_DIR)/devices -I$(UPSTREAM_DIR)/ios/deps/include -I$(UPSTREAM_DIR)/ios/deps/include/slirp -I$(UPSTREAM_DIR)/ios/deps/include/glib-2.0 -I$(UPSTREAM_DIR)/ios/deps/lib/glib-2.0/include

$(BUILD_DIR)/ios/%.o: host/%.c $(HOST_HDRS) | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang $(IOS_CFLAGS) -c $< -o $@

$(BUILD_DIR)/ios/henge_brk.o: host/henge_brk.S | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=26.0 -isysroot "$(IOS_SDK)" -c $< -o $@

$(BUILD_DIR)/ios/up_core_mmu.o: $(UPSTREAM_DIR)/core/mmu.c | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang $(IOS_UP_CFLAGS) $(ENG_INC) -mgeneral-regs-only -c $< -o $@

$(BUILD_DIR)/ios/up_host_enter.o: $(UPSTREAM_DIR)/host/enter.S | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=26.0 -isysroot "$(IOS_SDK)" -c $< -o $@

$(BUILD_DIR)/ios/up_dev_fb_metal.o: $(UPSTREAM_DIR)/devices/fb_metal.m | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter $(IOS_BASE) $(ENG_INC) -c $< -o $@

$(BUILD_DIR)/ios/up_core_%.o: $(UPSTREAM_DIR)/core/%.c | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang $(IOS_UP_CFLAGS) $(ENG_INC) -c $< -o $@

$(BUILD_DIR)/ios/up_host_%.o: $(UPSTREAM_DIR)/host/%.c | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang $(IOS_UP_CFLAGS) $(ENG_INC) -c $< -o $@

$(BUILD_DIR)/ios/up_dev_%.o: $(UPSTREAM_DIR)/devices/%.c | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	xcrun --sdk iphoneos clang $(IOS_UP_CFLAGS) $(ENG_INC) -c $< -o $@

ios-lib-full: $(IOS_HOST_OBJS) $(UPSTREAM_ALL_OBJS)
	rm -f $(BUILD_DIR)/ios/libhengelinux.a
	ar rcs $(BUILD_DIR)/ios/libhengelinux.a $(IOS_HOST_OBJS) $(UPSTREAM_ALL_OBJS)
	@echo "[ios-lib] Built $(BUILD_DIR)/ios/libhengelinux.a (full HengeVM engine)"
endif

ios-lib: $(HOST_SRCS) $(HOST_HDRS) host/henge_brk.S | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	@if [ "$(UNAME_S)" = "Darwin" ]; then \
		set -euo pipefail; \
		NCPU=$$(sysctl -n hw.ncpu); \
		if [ -f "$(UPSTREAM_DIR)/core/translate.c" ] && [ -f "$(UPSTREAM_DIR)/ios/deps/include/slirp/libslirp.h" ]; then \
			echo "[ios-lib] Compiling upstream WindowsiOS core/host/devices in parallel (-j$$NCPU)"; \
			$(MAKE) -j"$$NCPU" ios-lib-full; \
		elif [ "$(REQUIRE_UPSTREAM)" = "1" ]; then \
			echo "[ios-lib] ERROR: REQUIRE_UPSTREAM=1 but upstream engine or ios/deps is missing!" >&2; \
			exit 1; \
		else \
			echo "[ios-lib] Upstream engine or ios/deps not present; archiving host substrate only"; \
			$(MAKE) -j"$$NCPU" $(IOS_HOST_OBJS); \
			rm -f $(BUILD_DIR)/ios/libhengelinux.a; \
			ar rcs $(BUILD_DIR)/ios/libhengelinux.a $(IOS_HOST_OBJS); \
			echo "[ios-lib] Built $(BUILD_DIR)/ios/libhengelinux.a"; \
		fi; \
	else \
		echo "[ios-lib] Skipping iphoneos static archive on non-Darwin host"; \
	fi

sync-upstream:
	bash ./scripts/sync_upstream.sh

ios-project:
	xcodegen generate --spec ios/project.yml

clean:
	rm -rf $(BUILD_DIR) ios/HengeLinux.xcodeproj
