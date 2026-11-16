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

CC ?= cc
CFLAGS_COMMON := -std=c11 -O2 -Wall -Wextra -Werror -DHV_TLB_PAGE_BITS=$(HV_TLB_PAGE_BITS) -Ihost

BUILD_DIR := build
UPSTREAM_DIR := .upstream/WindowsiOS

.PHONY: all clean test-core hvsparse ios-lib sync-upstream ios-project

all: test-core hvsparse

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

HOST_SRCS := host/henge_platform.c host/henge_txm_jit.c host/henge_virtio_gpu.c
HOST_HDRS := host/henge_platform.h host/henge_txm_jit.h host/henge_virtio_gpu.h

$(BUILD_DIR)/test_core: tests/test_core.c $(HOST_SRCS) $(HOST_HDRS) | $(BUILD_DIR)
	$(CC) $(CFLAGS_COMMON) -pthread tests/test_core.c $(HOST_SRCS) -o $(BUILD_DIR)/test_core

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

ios-lib: $(HOST_SRCS) $(HOST_HDRS) host/henge_brk.S | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	@if [ "$(UNAME_S)" = "Darwin" ]; then \
		set -euo pipefail; \
		IOS_SDK=$$(xcrun --sdk iphoneos --show-sdk-path); \
		IOS_BASE="-O2 -arch arm64 -mios-version-min=26.0 -isysroot $$IOS_SDK -DHV_TLB_PAGE_BITS=$(HV_TLB_PAGE_BITS) -Ihost"; \
		IOS_CFLAGS="-std=c11 -Wall -Wextra -Werror $$IOS_BASE"; \
		xcrun --sdk iphoneos clang $$IOS_CFLAGS -c host/henge_platform.c -o $(BUILD_DIR)/ios/henge_platform.o; \
		xcrun --sdk iphoneos clang $$IOS_CFLAGS -c host/henge_txm_jit.c -o $(BUILD_DIR)/ios/henge_txm_jit.o; \
		xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=26.0 -isysroot "$$IOS_SDK" -c host/henge_brk.S -o $(BUILD_DIR)/ios/henge_brk.o; \
		xcrun --sdk iphoneos clang $$IOS_CFLAGS -c host/henge_virtio_gpu.c -o $(BUILD_DIR)/ios/henge_virtio_gpu.o; \
		OBJS="$(BUILD_DIR)/ios/henge_platform.o $(BUILD_DIR)/ios/henge_txm_jit.o $(BUILD_DIR)/ios/henge_brk.o $(BUILD_DIR)/ios/henge_virtio_gpu.o"; \
		if [ -f "$(UPSTREAM_DIR)/core/translate.c" ] && [ -f "$(UPSTREAM_DIR)/ios/deps/include/slirp/libslirp.h" ]; then \
			echo "[ios-lib] Compiling upstream WindowsiOS core/host/devices into libhengelinux.a"; \
			ENG_INC="-I$(UPSTREAM_DIR)/core -I$(UPSTREAM_DIR)/host -I$(UPSTREAM_DIR)/devices -I$(UPSTREAM_DIR)/ios/deps/include -I$(UPSTREAM_DIR)/ios/deps/include/slirp -I$(UPSTREAM_DIR)/ios/deps/include/glib-2.0 -I$(UPSTREAM_DIR)/ios/deps/lib/glib-2.0/include"; \
			xcrun --sdk iphoneos clang -std=c11 $$IOS_BASE $$ENG_INC -mgeneral-regs-only -c $(UPSTREAM_DIR)/core/mmu.c -o $(BUILD_DIR)/ios/up_mmu.o; \
			xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=26.0 -isysroot "$$IOS_SDK" -c $(UPSTREAM_DIR)/host/enter.S -o $(BUILD_DIR)/ios/up_enter.o; \
			xcrun --sdk iphoneos clang -fobjc-arc $$IOS_BASE $$ENG_INC -c $(UPSTREAM_DIR)/devices/fb_metal.m -o $(BUILD_DIR)/ios/up_fb_metal.o; \
			OBJS="$$OBJS $(BUILD_DIR)/ios/up_mmu.o $(BUILD_DIR)/ios/up_enter.o $(BUILD_DIR)/ios/up_fb_metal.o"; \
			for src in $(UPSTREAM_CORE_SRCS) $(UPSTREAM_HOST_SRCS) $(UPSTREAM_DEV_SRCS); do \
				obj="$(BUILD_DIR)/ios/up_$$(basename "$$src" .c).o"; \
				xcrun --sdk iphoneos clang -std=c11 $$IOS_BASE $$ENG_INC -c "$$src" -o "$$obj"; \
				OBJS="$$OBJS $$obj"; \
			done; \
		else \
			echo "[ios-lib] Upstream engine or ios/deps not present; archiving host substrate only"; \
		fi; \
		rm -f $(BUILD_DIR)/ios/libhengelinux.a; \
		ar rcs $(BUILD_DIR)/ios/libhengelinux.a $$OBJS; \
		echo "[ios-lib] Built $(BUILD_DIR)/ios/libhengelinux.a"; \
	else \
		echo "[ios-lib] Skipping iphoneos static archive on non-Darwin host"; \
	fi

sync-upstream:
	bash ./scripts/sync_upstream.sh

ios-project:
	xcodegen generate --spec ios/project.yml

clean:
	rm -rf $(BUILD_DIR) ios/HengeLinux.xcodeproj
