#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile and validate static arm64-apple-ios18.0 3D graphics dependencies:
#   1. Google ANGLE (Metal-only static archives: libEGL.a, libGLESv2.a)
#      Pinned: godotengine/godot-angle-static tag chromium/7578 (89bab1e / ANGLE d39da9a)
#   2. libepoxy 1.5.10 (libepoxy.a, patched for static ANGLE iOS dispatch)
#      Pinned: libepoxy-1.5.10.tar.xz (SHA256 072cda4b59dd098bba8c2363a6247299db1fa89411dc221c8b81b8ee8192e623)
#   3. libvirglrenderer 1.2.0 (libvirglrenderer.a, -Dplatforms=egl -Dvenus=false)
#      Pinned: gitlab.freedesktop.org/virgl/virglrenderer tag 1.2.0

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "[gpu-deps] Skipping iOS GPU dependency cross-compile: Darwin/Xcode required."
    exit 0
fi

if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local/Homebrew" ] || [ -d "/usr/local/Cellar" ]; then
    BREW_PREFIX="/usr/local"
else
    echo "[gpu-deps] Homebrew not found in /opt/homebrew or /usr/local" >&2
    exit 1
fi

export PATH="$BREW_PREFIX/bin:$PATH"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-18.0}"
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN_VERSION"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
GPU_DEPS="$ROOT_DIR/.upstream/WindowsiOS/ios/gpu-deps"
WORK_DIR="$ROOT_DIR/.upstream/WindowsiOS/work/ios_gpu_deps_build"

ANGLE_REPO="https://github.com/godotengine/godot-angle-static.git"
ANGLE_TAG="chromium/7578"
EPOXY_VER="1.5.10"
EPOXY_URL="https://download.gnome.org/sources/libepoxy/1.5/libepoxy-${EPOXY_VER}.tar.xz"
EPOXY_SHA256="072cda4b59dd098bba8c2363a6247299db1fa89411dc221c8b81b8ee8192e623"
VIRGL_VER="1.2.0"
VIRGL_URL="https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/${VIRGL_VER}/virglrenderer-${VIRGL_VER}.tar.gz"

REQUIRED_LIBS=(libEGL.a libGLESv2.a libepoxy.a libvirglrenderer.a)
REQUIRED_HDRS=(
    "$GPU_DEPS/include/EGL/egl.h"
    "$GPU_DEPS/include/GLES3/gl3.h"
    "$GPU_DEPS/include/epoxy/egl.h"
    "$GPU_DEPS/include/epoxy/gl.h"
    "$GPU_DEPS/include/virglrenderer.h"
)

have_all_cached=1
for lib in "${REQUIRED_LIBS[@]}"; do
    [ -s "$GPU_DEPS/lib/$lib" ] || have_all_cached=0
done
for hdr in "${REQUIRED_HDRS[@]}"; do
    [ -s "$hdr" ] || have_all_cached=0
done

if [ "$have_all_cached" -eq 1 ] && [ "${FORCE_REBUILD_GPU_DEPS:-0}" != "1" ]; then
    echo "[gpu-deps] Using cached iOS arm64 static 3D GPU archives in $GPU_DEPS"
    ls -lh "$GPU_DEPS/lib"
    exit 0
fi

for tool in meson ninja pkg-config python3 scons curl git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[gpu-deps] Missing required host tool: $tool (install via: brew install $tool)" >&2
        exit 1
    fi
done

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CC_BIN="$(xcrun --sdk iphoneos --find clang)"
CXX_BIN="$(xcrun --sdk iphoneos --find clang++)"
AR_BIN="$(xcrun --sdk iphoneos --find ar)"
STRIP_BIN="$(xcrun --sdk iphoneos --find strip)"
LIBTOOL_BIN="$(xcrun --sdk iphoneos --find libtool)"
NCPU="$(sysctl -n hw.ncpu)"

mkdir -p "$GPU_DEPS/lib/pkgconfig" "$GPU_DEPS/include" "$WORK_DIR"

# Generate shared Meson cross-file for arm64-apple-ios${IOS_MIN_VERSION}
CROSS_FILE="$WORK_DIR/ios-arm64-cross.ini"
cat <<EOF > "$CROSS_FILE"
[binaries]
c = '$CC_BIN'
cpp = '$CXX_BIN'
objc = '$CC_BIN'
objcpp = '$CXX_BIN'
ar = '$AR_BIN'
strip = '$STRIP_BIN'
pkg-config = '$(command -v pkg-config)'

[built-in options]
c_args = ['-arch', 'arm64', '-target', 'arm64-apple-ios${IOS_MIN_VERSION}', '-miphoneos-version-min=${IOS_MIN_VERSION}', '-isysroot', '$SDKROOT', '-I$GPU_DEPS/include', '-O2']
cpp_args = ['-arch', 'arm64', '-target', 'arm64-apple-ios${IOS_MIN_VERSION}', '-miphoneos-version-min=${IOS_MIN_VERSION}', '-isysroot', '$SDKROOT', '-I$GPU_DEPS/include', '-O2']
c_link_args = ['-arch', 'arm64', '-target', 'arm64-apple-ios${IOS_MIN_VERSION}', '-miphoneos-version-min=${IOS_MIN_VERSION}', '-isysroot', '$SDKROOT', '-L$GPU_DEPS/lib', '-lc++', '-framework', 'Metal', '-framework', 'IOSurface', '-framework', 'QuartzCore', '-framework', 'CoreFoundation']
cpp_link_args = ['-arch', 'arm64', '-target', 'arm64-apple-ios${IOS_MIN_VERSION}', '-miphoneos-version-min=${IOS_MIN_VERSION}', '-isysroot', '$SDKROOT', '-L$GPU_DEPS/lib', '-lc++', '-framework', 'Metal', '-framework', 'IOSurface', '-framework', 'QuartzCore', '-framework', 'CoreFoundation']

[properties]
pkg_config_libdir = '$GPU_DEPS/lib/pkgconfig'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

# ---------------------------------------------------------------------------
# 1. Google ANGLE (Metal-only static archives: libEGL.a, libGLESv2.a)
# ---------------------------------------------------------------------------
if [ ! -s "$GPU_DEPS/lib/libEGL.a" ] || [ ! -s "$GPU_DEPS/lib/libGLESv2.a" ] || [ ! -s "$GPU_DEPS/include/EGL/egl.h" ] || [ "${FORCE_REBUILD_GPU_DEPS:-0}" = "1" ]; then
    echo "[gpu-deps] Building Metal-only static Google ANGLE ($ANGLE_TAG) for arm64-apple-ios${IOS_MIN_VERSION}"
    ANGLE_DIR="$WORK_DIR/godot-angle-static"
    if [ ! -d "$ANGLE_DIR/.git" ]; then
        rm -rf "$ANGLE_DIR"
        git clone --depth 1 --branch "$ANGLE_TAG" "$ANGLE_REPO" "$ANGLE_DIR"
        # Initialize only godot-angle-static's direct submodules (angle, astc-encoder, zlib)
        # without --recursive so angle's private chrome-internal.googlesource.com submodules are skipped.
        git -C "$ANGLE_DIR" submodule update --init --depth 1
    fi
    python3 "$SCRIPT_DIR/patch_gpu_deps.py" angle "$ANGLE_DIR" "$IOS_MIN_VERSION"

    (
        cd "$ANGLE_DIR"
        scons -j"$NCPU" \
            platform=ios \
            arch=arm64 \
            ios_simulator=no \
            ios_min_version="$IOS_MIN_VERSION" \
            debug_symbols=no
    )

    # Collect produced ANGLE static libraries (godot-angle-static emits
    # bin/libEGL.ios.arm64.a, bin/libGLES.ios.arm64.a, and bin/libANGLE.ios.arm64.a).
    EGL_ARCHIVE="$(find "$ANGLE_DIR/bin" -maxdepth 3 -name 'libEGL*.a' -type f | head -n 1 || true)"
    GLES_ARCHIVE="$(find "$ANGLE_DIR/bin" -maxdepth 3 \( -name 'libGLESv2*.a' -o -name 'libGLES*.a' \) -type f | head -n 1 || true)"
    EXTRA_ARCHIVES=()
    while IFS= read -r libf; do
        [ -n "$libf" ] || continue
        base="$(basename "$libf")"
        case "$base" in
            libEGL*.a|libGLES*.a) ;;
            *.a) EXTRA_ARCHIVES+=("$libf") ;;
        esac
    done < <(find "$ANGLE_DIR/bin" -maxdepth 3 -name '*.a' -type f 2>/dev/null || true)

    if [ -z "$EGL_ARCHIVE" ] || [ -z "$GLES_ARCHIVE" ]; then
        echo "[gpu-deps] ERROR: ANGLE build did not produce libEGL / libGLES archives" >&2
        find "$ANGLE_DIR" -maxdepth 4 -name '*.a' >&2 || true
        exit 1
    fi

    cp "$EGL_ARCHIVE" "$GPU_DEPS/lib/libEGL.a"
    if [ "${#EXTRA_ARCHIVES[@]}" -gt 0 ]; then
        "$LIBTOOL_BIN" -static -o "$GPU_DEPS/lib/libGLESv2.a" "$GLES_ARCHIVE" "${EXTRA_ARCHIVES[@]}"
    else
        cp "$GLES_ARCHIVE" "$GPU_DEPS/lib/libGLESv2.a"
    fi

    ANGLE_INC_SRC="$ANGLE_DIR/angle/include"
    for inc_sub in EGL GLES2 GLES3 KHR; do
        if [ -d "$ANGLE_INC_SRC/$inc_sub" ]; then
            rm -rf "$GPU_DEPS/include/$inc_sub"
            cp -R "$ANGLE_INC_SRC/$inc_sub" "$GPU_DEPS/include/$inc_sub"
        fi
    done

    # Generate pkg-config descriptors for libepoxy & libvirglrenderer
    cat <<EOF > "$GPU_DEPS/lib/pkgconfig/egl.pc"
prefix=$GPU_DEPS
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: egl
Description: Google ANGLE Metal EGL (static iOS arm64)
Version: 1.5
Libs: -L\${libdir} -lEGL -lGLESv2 -lc++ -framework Metal -framework IOSurface -framework QuartzCore -framework CoreFoundation
Cflags: -I\${includedir} -DKHRONOS_STATIC
EOF

    cat <<EOF > "$GPU_DEPS/lib/pkgconfig/glesv2.pc"
prefix=$GPU_DEPS
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: glesv2
Description: Google ANGLE Metal OpenGL ES 3.0 (static iOS arm64)
Version: 3.0
Libs: -L\${libdir} -lGLESv2 -lc++ -framework Metal -framework IOSurface -framework QuartzCore -framework CoreFoundation
Cflags: -I\${includedir} -DKHRONOS_STATIC
EOF
else
    echo "[gpu-deps] Using cached ANGLE archives in $GPU_DEPS/lib"
fi

# ---------------------------------------------------------------------------
# 2. libepoxy 1.5.10 (static, direct ANGLE dispatch on iOS)
# ---------------------------------------------------------------------------
if [ ! -s "$GPU_DEPS/lib/libepoxy.a" ] || [ ! -s "$GPU_DEPS/include/epoxy/egl.h" ] || [ "${FORCE_REBUILD_GPU_DEPS:-0}" = "1" ]; then
    echo "[gpu-deps] Cross-compiling libepoxy ${EPOXY_VER} for arm64-apple-ios${IOS_MIN_VERSION}"
    EPOXY_TAR="$WORK_DIR/libepoxy-${EPOXY_VER}.tar.xz"
    if [ ! -s "$EPOXY_TAR" ]; then
        curl -fL --retry 3 -o "${EPOXY_TAR}.part" "$EPOXY_URL"
        mv "${EPOXY_TAR}.part" "$EPOXY_TAR"
    fi
    GOT_SHA="$(shasum -a 256 "$EPOXY_TAR" | awk '{print $1}')"
    if [ "$GOT_SHA" != "$EPOXY_SHA256" ]; then
        echo "[gpu-deps] ERROR: libepoxy SHA256 mismatch (got $GOT_SHA, expected $EPOXY_SHA256)" >&2
        rm -f "$EPOXY_TAR"
        exit 1
    fi
    EPOXY_SRC="$WORK_DIR/libepoxy-${EPOXY_VER}"
    EPOXY_BLD="$WORK_DIR/libepoxy-build"
    rm -rf "$EPOXY_SRC" "$EPOXY_BLD"
    tar -xf "$EPOXY_TAR" -C "$WORK_DIR"
    python3 "$SCRIPT_DIR/patch_gpu_deps.py" epoxy "$EPOXY_SRC" "$IOS_MIN_VERSION"

    PKG_CONFIG_LIBDIR="$GPU_DEPS/lib/pkgconfig" \
    meson setup "$EPOXY_BLD" "$EPOXY_SRC" \
        --cross-file "$CROSS_FILE" \
        --prefix "$GPU_DEPS" \
        --default-library=static \
        --buildtype=release \
        -Degl=yes \
        -Dglx=no \
        -Dx11=false \
        -Ddocs=false \
        -Dtests=false
    ninja -C "$EPOXY_BLD" -j"$NCPU"
    ninja -C "$EPOXY_BLD" install
else
    echo "[gpu-deps] Using cached libepoxy.a in $GPU_DEPS/lib"
fi

# ---------------------------------------------------------------------------
# 3. libvirglrenderer 1.2.0 (static, EGL/GLES only, Venus disabled)
# ---------------------------------------------------------------------------
if [ ! -s "$GPU_DEPS/lib/libvirglrenderer.a" ] || [ ! -s "$GPU_DEPS/include/virglrenderer.h" ] || [ "${FORCE_REBUILD_GPU_DEPS:-0}" = "1" ]; then
    echo "[gpu-deps] Cross-compiling libvirglrenderer ${VIRGL_VER} for arm64-apple-ios${IOS_MIN_VERSION}"
    VIRGL_TAR="$WORK_DIR/virglrenderer-${VIRGL_VER}.tar.gz"
    if [ ! -s "$VIRGL_TAR" ]; then
        curl -fL --retry 3 -o "${VIRGL_TAR}.part" "$VIRGL_URL"
        mv "${VIRGL_TAR}.part" "$VIRGL_TAR"
    fi
    VIRGL_SRC="$WORK_DIR/virglrenderer-${VIRGL_VER}"
    VIRGL_BLD="$WORK_DIR/virglrenderer-build"
    rm -rf "$VIRGL_SRC" "$VIRGL_BLD"
    tar -xzf "$VIRGL_TAR" -C "$WORK_DIR"
    python3 "$SCRIPT_DIR/patch_gpu_deps.py" virgl "$VIRGL_SRC" "$IOS_MIN_VERSION"

    VIRGL_OPT_FILE=""
    if [ -f "$VIRGL_SRC/meson.options" ]; then
        VIRGL_OPT_FILE="$VIRGL_SRC/meson.options"
    elif [ -f "$VIRGL_SRC/meson_options.txt" ]; then
        VIRGL_OPT_FILE="$VIRGL_SRC/meson_options.txt"
    fi

    VIRGL_MESON_ARGS=(
        --cross-file "$CROSS_FILE"
        --prefix "$GPU_DEPS"
        --default-library=static
        --buildtype=release
    )
    if [ -n "$VIRGL_OPT_FILE" ]; then
        while IFS= read -r opt_arg; do
            [ -n "$opt_arg" ] && VIRGL_MESON_ARGS+=("$opt_arg")
        done < <(python3 -c '
import re, sys
from pathlib import Path
txt = Path(sys.argv[1]).read_text(encoding="utf-8")
def has_opt(name):
    return re.search(r"option\s*\(\s*[\x27\"]" + re.escape(name) + r"[\x27\"]", txt, re.S) is not None
if has_opt("platforms"):
    # Always use 'auto' so virglrenderer skips Linux-only GBM/X11 and relies on our
    # ANGLE Metal EGL callbacks (create_gl_context/destroy_gl_context/make_current).
    print("-Dplatforms=auto")
for name, val in [
    ("venus", "false"),
    ("minigbm_allocation", "false"),
    ("tests", "false"),
    ("video", "false"),
    ("render-server", "false"),
    ("valgrind", "false"),
    ("tracing", "none"),
    ("fuzzer", "false"),
    ("unstable-apis", "false"),
    ("drm-renderers", "[]"),
]:
    if has_opt(name):
        print(f"-D{name}={val}")
' "$VIRGL_OPT_FILE")
    fi
    echo "[gpu-deps] Configuring virglrenderer with: ${VIRGL_MESON_ARGS[*]}"

    # Ensure Meson's build-machine python3 can import PyYAML (required by virglrenderer src/gallium/meson.build).
    PY_WITH_YAML="$(command -v python3)"
    if ! "$PY_WITH_YAML" -c "import yaml" >/dev/null 2>&1; then
        PY_VENV="$WORK_DIR/pyyaml_venv"
        if [ ! -x "$PY_VENV/bin/python3" ]; then
            "$PY_WITH_YAML" -m venv "$PY_VENV"
            "$PY_VENV/bin/pip" install --quiet pyyaml
        fi
        PY_WITH_YAML="$PY_VENV/bin/python3"
    fi
    YAML_SITE="$("$PY_WITH_YAML" -c 'import pathlib, yaml; print(pathlib.Path(yaml.__file__).resolve().parent.parent)')"
    NATIVE_FILE="$WORK_DIR/ios-native.ini"
    cat <<EOF > "$NATIVE_FILE"
[binaries]
python3 = '$PY_WITH_YAML'
EOF

    PYTHONPATH="$YAML_SITE${PYTHONPATH:+:$PYTHONPATH}" \
    PKG_CONFIG_LIBDIR="$GPU_DEPS/lib/pkgconfig" \
    meson setup "$VIRGL_BLD" "$VIRGL_SRC" \
        --native-file "$NATIVE_FILE" \
        "${VIRGL_MESON_ARGS[@]}"
    PYTHONPATH="$YAML_SITE${PYTHONPATH:+:$PYTHONPATH}" \
    ninja -C "$VIRGL_BLD" -j"$NCPU"
    ninja -C "$VIRGL_BLD" install

    if [ -s "$GPU_DEPS/include/virgl/virglrenderer.h" ] && [ ! -s "$GPU_DEPS/include/virglrenderer.h" ]; then
        cp "$GPU_DEPS/include/virgl/virglrenderer.h" "$GPU_DEPS/include/virglrenderer.h"
    fi
else
    echo "[gpu-deps] Using cached libvirglrenderer.a in $GPU_DEPS/lib"
fi

for lib in "${REQUIRED_LIBS[@]}"; do
    if [ ! -s "$GPU_DEPS/lib/$lib" ]; then
        echo "[gpu-deps] ERROR: missing expected archive $GPU_DEPS/lib/$lib" >&2
        exit 1
    fi
done
for hdr in "${REQUIRED_HDRS[@]}"; do
    if [ ! -s "$hdr" ]; then
        echo "[gpu-deps] ERROR: missing expected header $hdr" >&2
        exit 1
    fi
done

echo "[gpu-deps] All iOS arm64 static 3D GPU dependencies ready:"
ls -lh "$GPU_DEPS/lib"
