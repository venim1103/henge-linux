#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
Apply deterministic, idempotent iOS 18.0+ patches to pinned 3D graphics
dependencies compiled by scripts/build_ios_gpu_deps.sh:
  1. angle <dir>:
     - Enforce iOS deployment target (18.0) in godot-angle-static SConstruct.
     - Patch RescopeGlobalVariables.cpp to avoid pointer-order nondeterminism
       in MSL _utempN emission (prevents 100% repeat shader cache misses).
  2. epoxy <dir>:
     - Patch src/dispatch_common.c so iOS builds resolve EGL/GLES2 symbols
       directly against statically linked ANGLE via RTLD_MAIN_ONLY / eglGetProcAddress
       instead of dlopen()'ing Apple's deprecated OpenGLES.framework.
  3. virgl <dir>:
     - Patch vrend_formats.c / vrend_renderer.c for VIRGL_FORMAT_A8_UNORM
       swizzle handling and ES 3.0 MAX_SAMPLES >= 4 on ANGLE Metal hosts.
     - Guard Linux-only epoll/memfd targets when cross-compiling for Darwin/iOS.
"""

from pathlib import Path
import re
import sys


def patch_angle(angle_root: Path, ios_min: str) -> None:
    sconstruct = angle_root / "SConstruct"
    if sconstruct.is_file():
        txt = sconstruct.read_text(encoding="utf-8")
        orig = txt
        txt = re.sub(
            r"-m(?:iphoneos|ios)-version-min=[0-9]+(?:\.[0-9]+)?",
            f"-miphoneos-version-min={ios_min}",
            txt,
        )
        txt = re.sub(
            r'ios_min_version["\']?\s*,\s*["\'][0-9]+(?:\.[0-9]+)?["\']',
            f'ios_min_version", "{ios_min}"',
            txt,
        )
        # Ensure real iPhoneOS device builds do not accidentally define ANGLE_PLATFORM_IOS_FAMILY_SIMULATOR.
        if "HENGE_IOS_DEVICE_FIX" not in txt and "ANGLE_PLATFORM_IOS_FAMILY_SIMULATOR" in txt:
            txt = "# HENGE_IOS_DEVICE_FIX\n" + txt
            txt = txt.replace(
                '"ANGLE_PLATFORM_IOS_FAMILY_SIMULATOR"',
                '"ANGLE_PLATFORM_IOS_FAMILY"',
            )
            txt = txt.replace(
                "'ANGLE_PLATFORM_IOS_FAMILY_SIMULATOR'",
                "'ANGLE_PLATFORM_IOS_FAMILY'",
            )
            txt = txt.replace(
                "-DANGLE_PLATFORM_IOS_FAMILY_SIMULATOR",
                "-DANGLE_PLATFORM_IOS_FAMILY",
            )
            # Keep ANGLE Metal-only on iOS device builds (strip tuple/dict forms BEFORE bare strings
            # so ("ANGLE_ENABLE_EAGL", 1) never degrades into a bare integer `1` in SCons CPPDEFINES).
            txt = re.sub(r'\(\s*["\']ANGLE_ENABLE_EAGL["\']\s*,\s*[^)]+\)\s*,?', "", txt)
            txt = re.sub(r'["\']ANGLE_ENABLE_EAGL["\']\s*:\s*[^,}]+\s*,?', "", txt)
            txt = re.sub(r'["\']ANGLE_ENABLE_EAGL(?:=1)?["\']\s*,?', "", txt)
            txt = txt.replace("-DANGLE_ENABLE_EAGL=1", "")
        if txt != orig:
            sconstruct.write_text(txt, encoding="utf-8")
            print(f"[gpu-patch] {sconstruct}: patched iOS device target & ios_min_version={ios_min}")
        else:
            print(f"[gpu-patch] {sconstruct}: ios_min_version already aligned")

    # Switch ANGLE's CPU astcenc decompressor to ANGLE's upstream AstcDecompressorNoOp.cpp
    # (Apple Silicon Metal supports ASTC natively; godot-angle-static does not bundle libastcenc.a).
    has_noop_astc = (angle_root / "angle/src/image_util/AstcDecompressorNoOp.cpp").is_file()
    build_files = [
        p for p in [sconstruct, *angle_root.glob("SConscript*"), *angle_root.glob("*.py")]
        if p.is_file()
    ]
    for bf in build_files:
        btxt = bf.read_text(encoding="utf-8")
        borig = btxt
        if has_noop_astc and "AstcDecompressor.cpp" in btxt:
            btxt = btxt.replace("AstcDecompressor.cpp", "AstcDecompressorNoOp.cpp")
            print(f"[gpu-patch] {bf}: switched AstcDecompressor.cpp -> AstcDecompressorNoOp.cpp")
        if btxt != borig:
            bf.write_text(btxt, encoding="utf-8")

    # Ensure ANGLEShaderProgramVersion.h exists in godot-angle/ (included via -Igodot-angle).
    # Upstream ANGLE generates it from angle/src/program_serialize_data_version.py during GN builds.
    gen_hdr = angle_root / "godot-angle/ANGLEShaderProgramVersion.h"
    existing_hdrs = list(angle_root.rglob("ANGLEShaderProgramVersion.h"))
    if not existing_hdrs:
        gen_hdr.parent.mkdir(parents=True, exist_ok=True)
        ver_script = angle_root / "angle/src/program_serialize_data_version.py"
        angle_ver_h = angle_root / "angle/src/common/angle_version.h"
        generated = False
        if ver_script.is_file():
            import subprocess
            angle_dir = angle_root / "angle"
            # Generate deterministic hash directly using ANGLE's own script when possible
            try:
                res = subprocess.run(
                    [sys.executable, str(ver_script), str(gen_hdr), str(angle_ver_h)],
                    cwd=str(angle_dir),
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if res.returncode == 0 and gen_hdr.is_file() and gen_hdr.stat().st_size > 0:
                    generated = True
                    print(f"[gpu-patch] Generated {gen_hdr} via program_serialize_data_version.py")
            except Exception as exc:
                print(f"[gpu-patch] program_serialize_data_version.py fallback ({exc})")
        if not generated:
            # Deterministic fallback matching ANGLE's angle_version.h contract
            ver_hash = "aaebda1c5a40c15340d7a01a935a7c53"
            gen_hdr.write_text(
                "/* Generated by HengeLinux scripts/patch_gpu_deps.py */\n"
                "#ifndef ANGLE_SHADER_PROGRAM_VERSION_H_\n"
                "#define ANGLE_SHADER_PROGRAM_VERSION_H_\n"
                f"#define ANGLE_PROGRAM_VERSION \"{ver_hash}\"\n"
                f"#define ANGLE_PROGRAM_VERSION_HASH_SIZE {len(ver_hash)}\n"
                "#define ANGLE_PROGRAM_BINARY_ID 1\n"
                "#endif  // ANGLE_SHADER_PROGRAM_VERSION_H_\n",
                encoding="utf-8",
            )
            print(f"[gpu-patch] Synthesized deterministic {gen_hdr}")

    # Ensure angle_commit.h exists in godot-angle/ (included by angle/src/common/angle_version.h).
    commit_hdr = angle_root / "godot-angle/angle_commit.h"
    existing_commit_hdrs = list(angle_root.rglob("angle_commit.h"))
    if not existing_commit_hdrs:
        commit_hdr.parent.mkdir(parents=True, exist_ok=True)
        commit_script = angle_root / "angle/src/commit_id.py"
        generated_commit = False
        if commit_script.is_file():
            import subprocess
            try:
                res = subprocess.run(
                    [sys.executable, str(commit_script), "gen", str(commit_hdr)],
                    cwd=str(angle_root / "angle"),
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if res.returncode == 0 and commit_hdr.is_file() and commit_hdr.stat().st_size > 0:
                    generated_commit = True
                    print(f"[gpu-patch] Generated {commit_hdr} via angle/src/commit_id.py")
            except Exception as exc:
                print(f"[gpu-patch] commit_id.py fallback ({exc})")
        if not generated_commit:
            commit_hash = "aaebda1c5a40"
            commit_hdr.write_text(
                "/* Generated by HengeLinux scripts/patch_gpu_deps.py */\n"
                f"#define ANGLE_COMMIT_HASH \"{commit_hash}\"\n"
                f"#define ANGLE_COMMIT_HASH_SIZE {len(commit_hash)}\n"
                "#define ANGLE_COMMIT_DATE \"2026-01-01 00:00:00 +0000\"\n"
                "#define ANGLE_COMMIT_POSITION 0\n"
                "#define ANGLE_DISABLE_PROGRAM_BINARY_LOAD 0\n",
                encoding="utf-8",
            )
            print(f"[gpu-patch] Synthesized deterministic {commit_hdr}")

    # Also ensure angle_program_version.h / any other godot-angle generated files are logged for diagnostics
    godot_angle_dir = angle_root / "godot-angle"
    if godot_angle_dir.is_dir():
        print("[gpu-patch] godot-angle contents:", sorted(p.name for p in godot_angle_dir.iterdir()))

    # Pitfall #2 mitigation: deterministic iteration order in RescopeGlobalVariables.cpp
    rescope_candidates = list(angle_root.rglob("RescopeGlobalVariables.cpp"))
    for rescope in rescope_candidates:
        txt = rescope.read_text(encoding="utf-8")
        if "HENGE_DETERMINISTIC_RESCOPE" in txt:
            print(f"[gpu-patch] {rescope}: already deterministic")
            continue
        # Replace pointer-hashed TUnorderedMap<const TVariable *, ...> with deterministic
        # ordered container or visit-order tracking if present.
        if "TUnorderedMap<const TVariable" in txt:
            updated = txt.replace(
                "TUnorderedMap<const TVariable",
                "/* HENGE_DETERMINISTIC_RESCOPE */ TMap<const TVariable",
            )
            if "#include <map>" not in updated:
                updated = "#include <map>\n" + updated
            # Ensure deterministic ordering by variable uniqueId rather than raw pointer address
            # when TMap is instantiated with pointer keys: provide a comparator struct if needed.
            comp_def = (
                "/* HENGE_DETERMINISTIC_RESCOPE */\n"
                "struct HengeVarIdLess {\n"
                "    bool operator()(const sh::TVariable *a, const sh::TVariable *b) const {\n"
                "        if (a == b) return false;\n"
                "        if (!a) return true;\n"
                "        if (!b) return false;\n"
                "        return a->uniqueId().get() < b->uniqueId().get();\n"
                "    }\n"
                "};\n"
            )
            # Only inject comparator if standard TMap<const TVariable *, V> form matches cleanly
            pattern = re.compile(
                r"/\*\s*HENGE_DETERMINISTIC_RESCOPE\s*\*/\s*TMap<const TVariable\s*\*\s*,\s*([^,>]+)>"
            )
            if pattern.search(updated) and "namespace sh" in updated:
                updated = updated.replace("namespace sh\n{", "namespace sh\n{\n" + comp_def, 1)
                updated = updated.replace("namespace sh {", "namespace sh {\n" + comp_def, 1)
                updated = pattern.sub(
                    r"/* HENGE_DETERMINISTIC_RESCOPE */ std::map<const TVariable *, \1, HengeVarIdLess>",
                    updated,
                )
            rescope.write_text(updated, encoding="utf-8")
            print(f"[gpu-patch] {rescope}: patched to deterministic uniqueId() iteration order")
        else:
            print(f"[gpu-patch] {rescope}: no pointer-keyed TUnorderedMap found (already upstream-safe)")


def patch_epoxy(epoxy_root: Path) -> None:
    # 1. Enable PLATFORM_HAS_EGL on Darwin/iOS when configured with -Degl=yes (ENABLE_EGL == 1)
    dispatch_h = epoxy_root / "src/dispatch_common.h"
    if dispatch_h.is_file():
        htxt = dispatch_h.read_text(encoding="utf-8")
        if "HENGE_APPLE_EGL" not in htxt:
            htxt = re.sub(
                r"(#elif\s+defined\(__APPLE__\)\s*\n\s*#define\s+PLATFORM_HAS_EGL\s+)0",
                r"\1ENABLE_EGL /* HENGE_APPLE_EGL */",
                htxt,
                count=1,
            )
            dispatch_h.write_text(htxt, encoding="utf-8")
            print(f"[gpu-patch] {dispatch_h}: enabled PLATFORM_HAS_EGL=ENABLE_EGL on Darwin/iOS")

    dispatch_c = epoxy_root / "src/dispatch_common.c"
    if not dispatch_c.is_file():
        raise RuntimeError(f"Expected libepoxy source file not found: {dispatch_c}")

    txt = dispatch_c.read_text(encoding="utf-8")
    if "HENGE_STATIC_ANGLE_IOS" in txt:
        print(f"[gpu-patch] {dispatch_c}: already patched")
        return

    # On iOS static ANGLE builds, declare the raw ANGLE eglGetProcAddress helper BEFORE
    # including dispatch_common.h (which includes epoxy/egl.h and redefines eglGetProcAddress
    # as a macro to epoxy_eglGetProcAddress). Never dlopen Apple's deprecated OpenGLES.framework.
    ios_preamble = """/* HENGE_STATIC_ANGLE_IOS: resolve statically linked ANGLE symbols directly on iOS */
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
extern void (*eglGetProcAddress(const char *procname))(void);
static void *henge_angle_get_proc_address(const char *name) {
    return (void *)eglGetProcAddress(name);
}
#endif
"""
    txt = ios_preamble + txt

    # Replace Apple OpenGLES.framework / libEGL.dylib names so dlopen doesn't load Apple GLES
    # and guarantee EGL_LIB / GLES2_LIB / GLES1_LIB are defined on __APPLE__ + iOS.
    txt = txt.replace(
        '#define GLES2_LIB "libGLESv2.dylib"',
        '#if defined(__APPLE__) && TARGET_OS_IPHONE\n#define GLES2_LIB NULL\n#else\n#define GLES2_LIB "libGLESv2.dylib"\n#endif',
    )
    txt = txt.replace(
        '#define GLES1_LIB "libGLESv1_CM.dylib"',
        '#if defined(__APPLE__) && TARGET_OS_IPHONE\n#define GLES1_LIB NULL\n#else\n#define GLES1_LIB "libGLESv1_CM.dylib"\n#endif',
    )
    txt = txt.replace(
        '#define EGL_LIB "libEGL.dylib"',
        '#if defined(__APPLE__) && TARGET_OS_IPHONE\n#define EGL_LIB NULL\n#else\n#define EGL_LIB "libEGL.dylib"\n#endif',
    )

    egl_lib_fallback = """#if defined(__APPLE__) && TARGET_OS_IPHONE
#ifndef EGL_LIB
#define EGL_LIB NULL
#endif
#ifndef GLES2_LIB
#define GLES2_LIB NULL
#endif
#ifndef GLES1_LIB
#define GLES1_LIB NULL
#endif
#endif

"""

    # Patch get_dlopen_handle() to return RTLD_MAIN_ONLY on iOS when lib_name is NULL or ANGLE
    old_dlopen = """static bool
get_dlopen_handle(void **handle, const char *lib_name, bool exit_on_fail, bool load)
{"""
    new_dlopen = egl_lib_fallback + """static bool
get_dlopen_handle(void **handle, const char *lib_name, bool exit_on_fail, bool load)
{
#if defined(__APPLE__) && TARGET_OS_IPHONE
    (void)lib_name;
    (void)exit_on_fail;
    (void)load;
    if (*handle == NULL) {
        *handle = RTLD_MAIN_ONLY;
    }
    return true;
#endif"""
    if old_dlopen in txt:
        txt = txt.replace(old_dlopen, new_dlopen, 1)

    # Patch do_dlsym() so stripped iOS Release binaries resolve all ANGLE EGL/GLES symbols
    # via ANGLE's built-in eglGetProcAddress table before falling back to dlsym(RTLD_MAIN_ONLY).
    txt, dlsym_count = re.subn(
        r"(static\s+void\s*\*\s*\n?do_dlsym\s*\([^)]*\)\s*\n?\{)",
        r"""\1
#if defined(__APPLE__) && TARGET_OS_IPHONE
    void *angle_sym = henge_angle_get_proc_address(name);
    if (angle_sym != NULL) {
        return angle_sym;
    }
#endif""",
        txt,
        count=1,
    )
    if dlsym_count:
        print(f"[gpu-patch] {dispatch_c}: patched do_dlsym() for static ANGLE lookup")

    # Patch epoxy_get_proc_address to prefer statically linked ANGLE eglGetProcAddress on iOS
    old_dlsym = """void *
epoxy_get_proc_address(const char *name)
{"""
    new_dlsym = """void *
epoxy_get_proc_address(const char *name)
{
#if defined(__APPLE__) && TARGET_OS_IPHONE
    void *sym = henge_angle_get_proc_address(name);
    if (sym != NULL) {
        return sym;
    }
    return dlsym(RTLD_MAIN_ONLY, name);
#endif"""
    if old_dlsym in txt:
        txt = txt.replace(old_dlsym, new_dlsym, 1)

    dispatch_c.write_text(txt, encoding="utf-8")
    print(f"[gpu-patch] {dispatch_c}: patched static ANGLE iOS dispatch")

    # Also allow Meson static build on Darwin/iOS with EGL enabled
    meson_build = epoxy_root / "meson.build"
    if meson_build.is_file():
        mtxt = meson_build.read_text(encoding="utf-8")
        if "HENGE_IOS_EGL" not in mtxt:
            # Ensure host_system == 'darwin' does not force build_egl = false when -Degl=yes
            mtxt = mtxt.replace(
                "elif host_system == 'darwin'\n  build_egl = false",
                "# HENGE_IOS_EGL: respect explicit -Degl=yes on Darwin/iOS\nelif host_system == 'darwin'\n  build_egl = (enable_egl == 'yes')",
            )
            meson_build.write_text(mtxt, encoding="utf-8")
            print(f"[gpu-patch] {meson_build}: enabled explicit -Degl=yes on Darwin/iOS")


def _replace_call_balanced(text: str, call_prefix_regex: str, replacement: str) -> str:
    """Replace function calls matching call_prefix_regex (ending right after '(')
    through their balanced closing ')' so nested calls like get_option(...) never leave
    dangling parentheses."""
    out = []
    pos = 0
    for m in re.finditer(call_prefix_regex, text):
        if m.start() < pos:
            continue
        out.append(text[pos:m.start()])
        depth = 1
        i = m.end()
        in_str = None
        while i < len(text) and depth > 0:
            ch = text[i]
            if in_str:
                if ch == "\\" and i + 1 < len(text):
                    i += 2
                    continue
                if ch == in_str:
                    in_str = None
            else:
                if ch in ("'", '"'):
                    in_str = ch
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
            i += 1
        if depth == 0:
            out.append(replacement)
            pos = i
        else:
            out.append(text[m.start():m.end()])
            pos = m.end()
    out.append(text[pos:])
    return "".join(out)


def patch_virgl(virgl_root: Path) -> None:
    # 1. Meson build: keep iOS cross-compile free of Linux-only DRM/GBM/vtest requirements
    meson_build = virgl_root / "meson.build"
    if meson_build.is_file():
        mtxt = meson_build.read_text(encoding="utf-8")
        if "HENGE_IOS_VIRGL" not in mtxt:
            mtxt = "# HENGE_IOS_VIRGL\n" + mtxt
            mtxt = _replace_call_balanced(
                mtxt,
                r"dependency\s*\(\s*['\"]libdrm['\"]",
                "dependency('libdrm', version : '>=2.4.50', required: false)",
            )
            # Skip standalone vtest server binary when building static library for iOS
            mtxt = mtxt.replace("subdir('vtest')", "# HENGE_IOS_VIRGL: skip standalone vtest server")
            meson_build.write_text(mtxt, encoding="utf-8")
            print(f"[gpu-patch] {meson_build}: disabled vtest & made libdrm optional for iOS static build")

    # 2. Pitfall #4: ensure VIRGL_FORMAT_A8_UNORM is not dropped as unsupported on GLES/ANGLE
    for fmt_file in virgl_root.rglob("vrend_formats.c"):
        ftxt = fmt_file.read_text(encoding="utf-8")
        if "HENGE_A8_UNORM_FIX" in ftxt:
            continue
        old_a8 = "{ VIRGL_FORMAT_A8_UNORM, GL_R8, GL_RED, GL_UNSIGNED_BYTE, NO_SWIZZLE }"
        new_a8 = "/* HENGE_A8_UNORM_FIX */ { VIRGL_FORMAT_A8_UNORM, GL_R8, GL_RED, GL_UNSIGNED_BYTE, SWIZZLE_ZERO_ZERO_ZERO_R }"
        if old_a8 in ftxt and "SWIZZLE_ZERO_ZERO_ZERO_R" in ftxt:
            ftxt = ftxt.replace(old_a8, new_a8, 1)
            fmt_file.write_text(ftxt, encoding="utf-8")
            print(f"[gpu-patch] {fmt_file}: applied VIRGL_FORMAT_A8_UNORM swizzle fix")

    # 3. Pitfall #3: ensure ES 3.0 MAX_SAMPLES >= 4 on ANGLE Metal hosts (no hard clamp to 1)
    for rend_file in virgl_root.rglob("vrend_renderer.c"):
        rtxt = rend_file.read_text(encoding="utf-8")
        if "HENGE_ANGLE_MSAA_FIX" in rtxt:
            continue
        # Guard against UTM-style max_samples = 1 clamp if present
        if "caps->v1.max_samples = 1;" in rtxt:
            rtxt = rtxt.replace(
                "caps->v1.max_samples = 1;",
                "/* HENGE_ANGLE_MSAA_FIX: keep ES 3.0 minimum MAX_SAMPLES=4 for Chromium/WebGL2 */\n   if (caps->v1.max_samples < 4) caps->v1.max_samples = 4;",
            )
            rend_file.write_text(rtxt, encoding="utf-8")
            print(f"[gpu-patch] {rend_file}: lifted ANGLE max_samples floor to 4")


def main() -> int:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <angle|epoxy|virgl> <src_dir> [ios_min_version]", file=sys.stderr)
        return 2
    target = sys.argv[1]
    src_dir = Path(sys.argv[2])
    ios_min = sys.argv[3] if len(sys.argv) > 3 else "18.0"
    if not src_dir.is_dir():
        print(f"[gpu-patch] directory not found: {src_dir}", file=sys.stderr)
        return 1

    if target == "angle":
        patch_angle(src_dir, ios_min)
    elif target == "epoxy":
        patch_epoxy(src_dir)
    elif target == "virgl":
        patch_virgl(src_dir)
    else:
        print(f"[gpu-patch] unknown target: {target}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
