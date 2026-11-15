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

.PHONY: all clean test-core sync-upstream ios-project

all: test-core

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/test_core: tests/test_core.c host/henge_platform.c host/henge_platform.h | $(BUILD_DIR)
	$(CC) $(CFLAGS_COMMON) -pthread tests/test_core.c host/henge_platform.c -o $(BUILD_DIR)/test_core

test-core: $(BUILD_DIR)/test_core
	./$(BUILD_DIR)/test_core

sync-upstream:
	./scripts/sync_upstream.sh

ios-project:
	xcodegen generate --spec ios/project.yml

clean:
	rm -rf $(BUILD_DIR) ios/HengeLinux.xcodeproj
