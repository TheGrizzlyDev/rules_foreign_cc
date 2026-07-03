# TODO(TheGrizzlyDev): the Windows code paths in this file (the cp-on-msys
# branch of the export script, the .lib/.dll naming in _static_basename /
# _shared_basename, the import-lib pairing for shared libs) are written
# against the docs but have not been exercised on a Windows host. Validate
# with a Windows CI runner before claiming first-class support.

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_common")
load(
    "//foreign_cc:providers.bzl",
    "ForeignCcArtifactInfo",
    "ForeignCcCmakeInfo",
    "ForeignCcDepsInfo",
)
load(
    "//foreign_cc/private:cc_toolchain_util.bzl",
    "LibrariesToLinkInfo",
    "create_linking_info",
)
load(
    "//foreign_cc/private:framework.bzl",
    "CC_EXTERNAL_RULE_FRAGMENTS",
    "FOREIGN_CC_FRAMEWORK_COMMON_ATTRS",
    "InputFiles",
    "foreign_cc_install_action",
)
load(
    "//foreign_cc/private/framework:platform.bzl",
    "VcpkgTripletInfo",
)
load(
    "//toolchains/native_tools:tool_access.bzl",
    "get_autoconf_data",
    "get_automake_data",
    "get_cmake_data",
    "get_m4_data",
    "get_make_data",
    "get_ninja_data",
    "get_pkgconfig_data",
    "get_meson_data",
)
load("@vcpkg_exec_prefix//:defs.bzl", "EXEC_PREFIX")

_DEFAULT_TRIPLET = Label("//foreign_cc/private/framework:vcpkg_triplet_info")
_VCPKG_TOOLCHAIN_TYPE = Label("//toolchains:vcpkg_toolchain")

def _vcpkg_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(default_info = ctx.attr.vcpkg[DefaultInfo])]

vcpkg_toolchain = rule(
    implementation = _vcpkg_toolchain_impl,
    attrs = {
        "vcpkg": attr.label(
            mandatory = True,
            allow_files = True,
            cfg = "exec",
        ),
    },
)

def _resolve_triplet(ctx):
    triplet = ctx.attr.triplet[VcpkgTripletInfo].triplet
    if not triplet:
        fail(
            "vcpkg: no triplet mapping for the active platform. " +
            "Override `triplet = ...` with a target providing VcpkgTripletInfo " +
            "(see foreign_cc/private/framework/platform.bzl).",
        )
    return triplet

def _static_basename(name, is_windows):
    return name + ".lib" if is_windows else "lib" + name + ".a"

def _shared_basename(name, is_windows, is_macos):
    if is_windows:
        return name + ".dll"
    if is_macos:
        return "lib" + name + ".dylib"
    return "lib" + name + ".so"

def _extract_lib_file(ctx, export_dir, subdir, basename):
    """Declare a File for `<export_dir>/<subdir>/<basename>` and emit a copy
    action that materializes it out of the tree-artifact `export_dir`.

    cc_common APIs need concrete File objects, so we can't reference entries
    inside the tree directly — they aren't tracked individually at analysis
    time. Copying lets us hand the linker a real File and lets cc_binary
    pick up shared libraries as runfiles automatically.
    """
    out = ctx.actions.declare_file(
        "{}_libs/{}/{}".format(ctx.attr.name, subdir, basename),
    )
    ctx.actions.run_shell(
        inputs = [export_dir],
        outputs = [out],
        command = "cp \"$1\" \"$2\"",
        arguments = ["{}/{}/{}".format(export_dir.path, subdir, basename), out.path],
        mnemonic = "VcpkgExtractLib",
        progress_message = "vcpkg_export: extracting {}/{}".format(subdir, basename),
    )
    return out

def _resolve_overlay_dirs(targets):
    """Map each overlay target to a single directory exec path.

    Accepts either a `bazel_skylib` `directory` target (uses DirectoryInfo.path)
    or a filegroup (uses the filegroup's package as the overlay root, which
    matches the conventional `filegroup(srcs = glob(["**/*"]))` shape).
    """
    dirs = []
    for tgt in targets:
        if DirectoryInfo in tgt:
            dirs.append(tgt[DirectoryInfo].path)
            continue
        files = tgt[DefaultInfo].files.to_list()
        if not files:
            fail("vcpkg_install: overlay target {} has no files.".format(tgt.label))
        # Walk up from any file's dir until we hit the filegroup's package
        # path. For `filegroup(srcs = glob(["**/*"]))` in package P, every
        # file's path is `<exec_root>/P/...`, so we want `<exec_root>/P`.
        pkg = tgt.label.package
        f = files[0]
        # f.path = "<workspace_root>/<package>/<relative>". Find the
        # boundary by searching for "/<package>/" in the path.
        marker = "/" + pkg + "/"
        idx = f.path.find(marker)
        if idx < 0:
            dirs.append(f.dirname)
        else:
            dirs.append(f.path[:idx + len(marker) - 1])
    return dirs

_OVERRIDE_PAYLOAD_FIELDS = (
    "out_static_libs",
    "out_shared_libs",
    "out_interface_libs",
    "out_binaries",
    "out_headers_only",
    "defines",
)

_OVERRIDE_LIST_FIELDS = (
    "out_static_libs",
    "out_shared_libs",
    "out_interface_libs",
    "out_binaries",
    "defines",
)

def _expand_placeholders(s, triplet, package, field):
    """Substitute $$VCPKG_TRIPLET$$ / $$VCPKG_PACKAGE$$ (plus _UPPER/_LOWER
    variants) inside `s`. Any unknown $$VCPKG_*$$ placeholder is a hard
    error.

    `field` names the attribute or override field carrying `s`; it's only
    used to make the error message actionable.
    """
    subs = {
        "$$VCPKG_TRIPLET$$": triplet,
        "$$VCPKG_TRIPLET_UPPER$$": triplet.upper(),
        "$$VCPKG_TRIPLET_LOWER$$": triplet.lower(),
        "$$VCPKG_PACKAGE$$": package,
        "$$VCPKG_PACKAGE_UPPER$$": package.upper(),
        "$$VCPKG_PACKAGE_LOWER$$": package.lower(),
    }
    result = s
    for placeholder, value in subs.items():
        result = result.replace(placeholder, value)

    if "$$VCPKG_" in result:
        # Find the offending fragment for the error message.
        start = result.index("$$VCPKG_")
        end_marker = result.find("$$", start + 2)
        offending = result[start:end_marker + 2] if end_marker != -1 else result[start:]
        fail(
            "vcpkg: unknown placeholder {} in {} value \"{}\". Known placeholders: {}.".format(
                offending,
                field,
                s,
                ", ".join(sorted(subs.keys())),
            ),
        )
    return result

def _resolve_override(override_json, triplet, compilation_mode, package):
    """Pick the most-specific override entry for (triplet, compilation_mode).

    An entry's optional `triplet` / `compilation_mode` fields scope its
    applicability. An entry matches when each scoping field is either absent
    in the entry or equal to the active value. The "most specific" match —
    the one with the most scoping fields present — wins. Ties are resolved
    by entry order (earlier wins) so the JSON's order is meaningful.

    Returns a dict containing only the _OVERRIDE_PAYLOAD_FIELDS keys present
    in the picked entry, plus a `_mode_scoped` bool recording whether the
    picked entry had its `compilation_mode` field set. If no entry matches,
    returns {}.
    """
    if not override_json:
        return {}
    parsed = json.decode(override_json)
    entries = parsed.get("entries", [])

    best = None
    best_specificity = -1
    for entry in entries:
        entry_triplet = entry.get("triplet")
        entry_mode = entry.get("compilation_mode")
        if entry_triplet != None and entry_triplet != triplet:
            continue
        if entry_mode != None and entry_mode != compilation_mode:
            continue
        specificity = (1 if entry_triplet != None else 0) + (1 if entry_mode != None else 0)
        if specificity > best_specificity:
            best = entry
            best_specificity = specificity

    if best == None:
        return {}
    result = {}
    for k in _OVERRIDE_PAYLOAD_FIELDS:
        if k not in best:
            continue
        v = best[k]
        if k in _OVERRIDE_LIST_FIELDS:
            v = [_expand_placeholders(item, triplet, package, k) for item in v]
        result[k] = v
    result["_mode_scoped"] = best.get("compilation_mode") != None
    return result

# vcpkg invokes this with `{sha512} {url} {dst}`. We copy the Bazel-staged
# file at $VCPKG_BAZEL_ASSET_CACHE/<sha512> into the destination vcpkg
# requested. vcpkg validates the sha512 of the result after we return, so
# any mismatch fails loudly.
_ASSET_SERVE_SCRIPT = r"""#!/usr/bin/env bash
set -euo pipefail
sha="$1"
dst="$3"
src="$VCPKG_BAZEL_ASSET_CACHE/$sha"
if [ ! -f "$src" ]; then
  echo "vcpkg asset-serve: missing staged file for sha512 $sha at $src" >&2
  exit 1
fi
mkdir -p "$(dirname "$dst")"
cp "$src" "$dst"
"""

_VCPKG_EXPORT_SCRIPT = r"""#!/usr/bin/env bash
set -euo pipefail

install_tree="$1"
export_dir="$2"
triplet="$3"
package="$4"
base_rel="$5"
debug="$6"  # "1" -> use lib/share/pkgconfig from debug/; "0" -> release

shopt -s nullglob
list_candidates=("$install_tree/vcpkg/info/${package}_"*"_${triplet}.list")
if [ ${#list_candidates[@]} -eq 0 ]; then
  echo "vcpkg_export: no .list file for package='$package' triplet='$triplet' in $install_tree/vcpkg/info/" >&2
  exit 1
fi
listfile="${list_candidates[0]}"

mkdir -p "$export_dir"

# Decide which install-tree-relative entries are kept, and where they land
# inside the export tree. Returns the destination relative path on stdout, or
# empty if the entry should be skipped.
# vcpkg layout: include/* (release-only), lib/*, bin/* (Windows DLLs),
# share/*, lib/pkgconfig/*, tools/<port>/* (port-shipped binaries),
# debug/lib/*, debug/bin/*, debug/share/* (rare). Headers are not duplicated
# under debug/.
classify() {
  local rel="$1"
  if [ "$debug" = "1" ]; then
    case "$rel" in
      include/*) printf '%s' "$rel" ;;
      debug/lib/*) printf '%s' "${rel#debug/}" ;;
      debug/bin/*) printf '%s' "${rel#debug/}" ;;
      debug/share/*) printf '%s' "${rel#debug/}" ;;
      # Use release-side share/ for CMake config files. Most ports install
      # them only under <triplet>/share/<pkg>/; vcpkg's own debug-vs-release
      # split happens at the lib/binary level, not at the cmake-package level.
      share/*) printf '%s' "$rel" ;;
      tools/*) printf '%s' "$rel" ;;
      *) printf '' ;;
    esac
  else
    # Release mode: expose release-side files under their natural paths
    # AND preserve `debug/lib`/`debug/bin` under their original locations
    # so vcpkg-shipped CMake config files (which reference both variants
    # unconditionally) find every file they claim exists.
    case "$rel" in
      include/*|lib/*|bin/*|share/*|tools/*) printf '%s' "$rel" ;;
      debug/lib/*|debug/bin/*) printf '%s' "$rel" ;;
      *) printf '' ;;
    esac
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  # All entries are prefixed with "<triplet>/"; skip anything else.
  case "$line" in
    "$triplet/"*) ;;
    *) continue ;;
  esac
  rel="${line#$triplet/}"

  # Skip directory entries (vcpkg lists them with a trailing slash).
  case "$rel" in
    */) continue ;;
  esac

  dst="$(classify "$rel")"
  [ -z "$dst" ] && continue

  target="$export_dir/$dst"
  mkdir -p "$(dirname "$target")"

  case "${OSTYPE:-}" in
    msys*|cygwin*|win*)
      # Windows: NTFS symlinks need elevation or developer mode. Copy.
      cp "$install_tree/$triplet/$rel" "$target"
      ;;
    *)
      # POSIX: relative symlink. depth = (slashes in dst) + 1 ../'s from
      # the symlink's directory reach <export_dir>'s parent, from where
      # <base_rel> points at the install_tree.
      slashes="${dst//[^\/]/}"
      depth=$((${#slashes} + 1))
      prefix=""
      for ((i=0; i<depth; i++)); do prefix="../$prefix"; done
      ln -sfn "${prefix}${base_rel}/${triplet}/${rel}" "$target"
      ;;
  esac
done < "$listfile"
"""

def _vcpkg_export_impl(ctx):
    install_tree_files = ctx.attr.install_tree[DefaultInfo].files.to_list()
    if len(install_tree_files) != 1:
        fail("vcpkg_export: expected exactly one install_tree directory, got {}".format(len(install_tree_files)))
    install_tree = install_tree_files[0]

    triplet = _resolve_triplet(ctx)

    # If this package isn't present in the resolved (triplet, feature-subset)
    # cell — e.g. the user didn't select the feature that pulls it in —
    # return empty providers instead of trying to extract files that don't
    # exist. Downstream cc_library targets see nothing to link, which is
    # correct: the package genuinely wasn't installed.
    if ctx.attr.presence_json:
        presence = json.decode(ctx.attr.presence_json)
        triplet_subsets = presence.get(triplet, [])
        if triplet_subsets:
            selected = []
            if ctx.attr.features_flag != None:
                selected = ctx.attr.features_flag[BuildSettingInfo].value
            declared_set = {f: True for f in ctx.attr.declared_features}
            active = sorted([f for f in selected if f in declared_set])
            subset_key = ":".join(active)
            if subset_key not in triplet_subsets:
                return [
                    DefaultInfo(files = depset([])),
                    OutputGroupInfo(),
                    CcInfo(),
                    ForeignCcDepsInfo(artifacts = depset()),
                ]

    export_dir = ctx.actions.declare_directory(ctx.attr.name + "_export")

    # Relative path from export_dir's parent to install_tree. Resolves at action
    # time regardless of sandbox location, since Bazel preserves the relative
    # layout of TreeArtifacts under bazel-out/.
    base_rel = paths.relativize(install_tree.path, paths.dirname(export_dir.path))

    script = ctx.actions.declare_file(ctx.attr.name + "_export.sh")
    ctx.actions.write(
        output = script,
        content = _VCPKG_EXPORT_SCRIPT,
        is_executable = True,
    )

    compilation_mode = ctx.attr.compilation_mode or ctx.var["COMPILATION_MODE"]
    debug = compilation_mode == "dbg"

    override = _resolve_override(ctx.attr.override_json, triplet, compilation_mode, ctx.attr.package)

    ctx.actions.run(
        mnemonic = "VcpkgExport",
        executable = script,
        arguments = [
            install_tree.path,
            export_dir.path,
            triplet,
            ctx.attr.package,
            base_rel,
            "1" if debug else "0",
        ],
        inputs = [install_tree],
        outputs = [export_dir],
        progress_message = "vcpkg_export: linking {} ({}{})".format(
            ctx.attr.package,
            triplet,
            ", debug" if debug else "",
        ),
    )

    # Materialize each declared lib as a separate File copied out of the
    # export tree, then feed concrete File objects to cc_common so:
    #   - static libs link normally,
    #   - shared libs (.so/.dylib/.dll) propagate as runfiles to consumers,
    #   - on Windows the import lib (.lib) + DLL pair is correctly modeled.
    is_windows = "windows" in triplet
    is_macos = "osx" in triplet or "ios" in triplet
    static_files = []
    shared_files = []
    interface_files = []
    binary_files = []
    extra_runfiles = []
    if override.get("out_headers_only"):
        pass
    else:
        explicit_static = override.get("out_static_libs", [])
        explicit_shared = override.get("out_shared_libs", [])
        explicit_interface = override.get("out_interface_libs", [])
        any_explicit = explicit_static or explicit_shared or explicit_interface

        if not any_explicit:
            # Fallback: guess one static lib named after the package, with
            # the conventional +d suffix in debug.
            fallback_name = ctx.attr.package + ("d" if debug else "")
            explicit_static = [fallback_name]
        elif debug and not override.get("_mode_scoped"):
            # Mode-agnostic explicit override in debug mode: apply +d.
            explicit_static = [n + "d" for n in explicit_static]
            explicit_shared = [n + "d" for n in explicit_shared]
            explicit_interface = [n + "d" for n in explicit_interface]

        for name in explicit_static:
            static_files.append(_extract_lib_file(ctx, export_dir, "lib", _static_basename(name, is_windows)))
        for name in explicit_shared:
            shared_basename = _shared_basename(name, is_windows, is_macos)
            shared_dir = "bin" if is_windows else "lib"
            shared_file = _extract_lib_file(ctx, export_dir, shared_dir, shared_basename)
            shared_files.append(shared_file)
            extra_runfiles.append(shared_file)
            if is_windows:
                # Windows links against the import lib (.lib) sitting next to
                # static libs under lib/, not the DLL itself.
                interface_files.append(_extract_lib_file(ctx, export_dir, "lib", name + ".lib"))
        for name in explicit_interface:
            interface_files.append(_extract_lib_file(ctx, export_dir, "lib", _static_basename(name, is_windows)))

    # Binaries: vcpkg installs them under <triplet>/tools/<port>/<binary>.
    # On Windows the binary basename gains `.exe`.
    for name in override.get("out_binaries", []):
        basename = name + ".exe" if is_windows else name
        out = ctx.actions.declare_file(
            "{}/bin/{}".format(ctx.attr.name, basename),
        )
        ctx.actions.run_shell(
            inputs = [export_dir],
            outputs = [out],
            command = "cp \"$1\" \"$2\" && chmod +x \"$2\"",
            arguments = [
                "{}/tools/{}/{}".format(export_dir.path, ctx.attr.package, basename),
                out.path,
            ],
            mnemonic = "VcpkgExtractBin",
            progress_message = "vcpkg_export: extracting tools/{}/{}".format(ctx.attr.package, basename),
        )
        binary_files.append(out)

    # `defines` come from two sources: the rule attr (substituted here) and
    # the matched override entry (already substituted inside _resolve_override).
    expanded_defines = [
        _expand_placeholders(d, triplet, ctx.attr.package, "defines")
        for d in ctx.attr.defines
    ] + override.get("defines", [])
    compilation_context = cc_common.create_compilation_context(
        headers = depset([export_dir]),
        system_includes = depset([export_dir.path + "/include"]),
        defines = depset(expanded_defines),
    )

    linking_context = create_linking_info(
        ctx,
        [],
        LibrariesToLinkInfo(
            static_libraries = static_files,
            shared_libraries = shared_files,
            interface_libraries = interface_files,
        ),
    )

    dep_cc_infos = [dep[CcInfo] for dep in ctx.attr.deps]
    merged = cc_common.merge_cc_infos(cc_infos = [
        CcInfo(compilation_context = compilation_context, linking_context = linking_context),
    ] + dep_cc_infos)

    # Expose this export tree as a ForeignCcArtifactInfo so downstream
    # foreign_cc rules (cmake / configure_make / etc.) pick it up via
    # CMAKE_PREFIX_PATH and the $EXT_BUILD_DEPS staging. Transitive
    # ForeignCcDepsInfo from `deps` is merged so the prefix path covers
    # every vcpkg package in the chain.
    own_artifact = ForeignCcArtifactInfo(
        gen_dir = export_dir,
        bin_dir_name = "bin",
        dll_dir_name = "bin",
        lib_dir_name = "lib",
        include_dir_name = "include",
    )
    transitive_artifacts = []
    for dep in ctx.attr.deps:
        if ForeignCcDepsInfo in dep:
            transitive_artifacts.append(dep[ForeignCcDepsInfo].artifacts)

    # Propagate shared libraries (and any declared binaries) as runfiles so
    # consuming cc_binary/cc_test can find the .so/.dylib/.dll at runtime.
    # cc_common already wires dynamic_library into linker_input; the runfiles
    # cover the loader.
    runfiles = ctx.runfiles(files = extra_runfiles + binary_files)
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    # Default files: the export tree itself for "I want everything", plus
    # each declared binary so `bazel build :pkg` materializes them and
    # downstream `tools = [...]` consumers can address them directly.
    default_files = [export_dir] + binary_files

    # Per-basename output group so consumers can address one binary at a time
    # via `--output_groups=<basename>` (mirrors cc_external_rule_impl).
    output_groups = {f.basename: depset([f]) for f in binary_files}

    # Publish the vcpkg install tree location + triplet so the consuming
    # `cmake()` rule can set `VCPKG_INSTALLED_DIR` / `VCPKG_TARGET_TRIPLET`
    # cache entries. vcpkg-shipped `<pkg>Config.cmake` files hardcode
    # references to `${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/...`
    # and resolve wrong to `//...` otherwise. Every vcpkg_export in a
    # single vcpkg.source shares the same install tree so downstream sees
    # one consistent pair.
    cmake_info = ForeignCcCmakeInfo(cache_entries = {
        "VCPKG_INSTALLED_DIR": "$$EXT_BUILD_ROOT$$/" + install_tree.path,
        "VCPKG_TARGET_TRIPLET": triplet,
    })

    return [
        DefaultInfo(files = depset(default_files), runfiles = runfiles),
        OutputGroupInfo(**output_groups),
        merged,
        ForeignCcDepsInfo(artifacts = depset(
            direct = [own_artifact],
            transitive = transitive_artifacts,
        )),
        cmake_info,
    ]

vcpkg_export = rule(
    _vcpkg_export_impl,
    attrs = {
        "alwayslink": attr.bool(default = False),
        "static_suffix": attr.string(default = ""),
        "compilation_mode": attr.string(
            doc = (
                "Per-target override of Bazel's compilation mode. If unset, " +
                "the global `--compilation_mode` is used. `dbg` causes the " +
                "export to source libraries from `<triplet>/debug/lib/` " +
                "instead of `<triplet>/lib/`; headers still come from " +
                "`<triplet>/include/`."
            ),
            values = ["", "dbg", "opt", "fastbuild"],
            default = "",
        ),
        "defines": attr.string_list(
            doc = "Defines propagated to consumers of this package.",
            default = [],
        ),
        "deps": attr.label_list(
            doc = "Other vcpkg_export targets this package depends on.",
            providers = [CcInfo],
            default = [],
        ),
        "install_tree": attr.label(
            doc = "A vcpkg_install target whose install tree contains this package.",
            mandatory = True,
        ),
        "override_json": attr.string(
            doc = (
                "JSON-encoded override document. Shape: " +
                "`{\"entries\": [{\"triplet\"?: str, \"compilation_mode\"?: str, " +
                "\"out_static_libs\"?: [str], \"out_shared_libs\"?: [str], " +
                "\"out_interface_libs\"?: [str], \"out_binaries\"?: [str], " +
                "\"out_headers_only\"?: bool}, ...]}`. " +
                "Entries are scoped by their optional `triplet` and " +
                "`compilation_mode` fields; the most-specific match wins. " +
                "String values in the `out_*` lists and on the rule's " +
                "`defines` attr may use the placeholders " +
                "`$$VCPKG_TRIPLET$$`, `$$VCPKG_PACKAGE$$` (also the " +
                "`_UPPER` / `_LOWER` casing variants). Unknown placeholders " +
                "are a hard error."
            ),
            default = "",
        ),
        "package": attr.string(
            doc = "vcpkg package name to export from the install tree.",
            mandatory = True,
        ),
        "presence_json": attr.string(
            doc = (
                "JSON `{triplet: [subset_key, ...]}` recording which " +
                "(triplet, feature-subset) cells this package is installed " +
                "in. Populated by the module extension from per-subset " +
                "`depend-info` runs. Empty string skips the guard (target " +
                "always attempts extraction)."
            ),
            default = "",
        ),
        "features_flag": attr.label(
            doc = (
                "Same `string_list_flag` the sibling `vcpkg_install` reads. " +
                "Used with `presence_json` to decide whether this package " +
                "is present in the active (triplet, subset) cell."
            ),
            providers = [BuildSettingInfo],
        ),
        "declared_features": attr.string_list(
            doc = "Manifest-declared feature names (see `vcpkg_install.declared_features`).",
        ),
        "triplet": attr.label(
            doc = (
                "Target providing the vcpkg triplet via VcpkgTripletInfo. " +
                "Defaults to a built-in target that derives the triplet from " +
                "the active Bazel platform via select(). Override with your own " +
                "VcpkgTripletInfo-providing target for non-default triplets " +
                "(e.g. x64-linux-static)."
            ),
            default = _DEFAULT_TRIPLET,
            providers = [VcpkgTripletInfo],
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    fragments = ["cpp"],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    provides = [CcInfo],
)

def _vcpkg_install_impl(ctx):
    install_tree = ctx.actions.declare_directory("%s_install_tree" % ctx.attr.name)
    # Action-private scratch for vcpkg's mutable directories (buildtrees,
    # packages, downloads, home). Keeps the vcpkg root archive immutable so
    # concurrent actions don't fight over `buildtrees/vcpkg-running.lock`.
    scratch_dir = ctx.actions.declare_directory("%s_vcpkg_scratch" % ctx.attr.name)

    root_files = ctx.attr.root[DefaultInfo].files.to_list()

    tools_data = [
        get_cmake_data(ctx),
        get_ninja_data(ctx),
        get_make_data(ctx),
        get_pkgconfig_data(ctx),
        get_autoconf_data(ctx),
        get_automake_data(ctx),
        get_m4_data(ctx),
        get_meson_data(ctx),
    ]
    tools_files_paths = []
    tools_files_inputs = []
    tools_env = {}
    for td in tools_data:
        tools_files_paths.append(td.path)
        if td.target:
            tools_files_inputs += td.target.files.to_list()
        if td.env:
            tools_env.update(td.env)

    declared_inputs = [ctx.file.manifest] + root_files + tools_files_inputs

    triplet = _resolve_triplet(ctx)

    # Redirect every mutable vcpkg dir out of VCPKG_ROOT into this target's
    # action-private scratch directory so the vcpkg root archive stays
    # immutable and concurrent actions don't fight over a shared
    # `buildtrees/vcpkg-running.lock`.
    # Stage Bazel-fetched download files into <scratch>/asset-cache/<sha512>
    # and write a serve script that vcpkg invokes per asset. Each source file
    # is named after its sha512 (set by the capture repo at fetch time), so
    # we can read file.basename to recover the sha at action time.
    download_target = ctx.attr.downloads_by_triplet.get(triplet)
    download_files = download_target[DefaultInfo].files.to_list() if download_target else []

    serve_script = ctx.actions.declare_file(ctx.attr.name + "_vcpkg_asset_serve.sh")
    ctx.actions.write(
        output = serve_script,
        content = _ASSET_SERVE_SCRIPT,
        is_executable = True,
    )

    stage_lines = ["##mkdirs## $$EXT_BUILD_ROOT$$/{}/asset-cache".format(scratch_dir.path)]
    for src in download_files:
        stage_lines.append("cp \"$$EXT_BUILD_ROOT$$/{}\" \"$$EXT_BUILD_ROOT$$/{}/asset-cache/{}\"".format(
            src.path, scratch_dir.path, src.basename,
        ))

    # Optional vcpkg-configuration.json: must live next to the manifest so
    # vcpkg auto-loads it from --x-manifest-root.
    config_file = ctx.file.vcpkg_configuration
    if config_file != None and config_file.dirname != ctx.file.manifest.dirname:
        fail(
            "vcpkg_install: vcpkg_configuration ({}) must live in the same " +
            "Bazel package as manifest ({}); vcpkg auto-loads it from " +
            "--x-manifest-root.".format(config_file.path, ctx.file.manifest.path),
        )

    overlay_ports_dirs = _resolve_overlay_dirs(ctx.attr.overlay_ports)
    overlay_triplets_dirs = _resolve_overlay_dirs(ctx.attr.overlay_triplets)

    overlay_inputs = []
    for tgt in ctx.attr.overlay_ports + ctx.attr.overlay_triplets:
        overlay_inputs += tgt[DefaultInfo].files.to_list()

    toolchain = ctx.toolchains[_VCPKG_TOOLCHAIN_TYPE]
    vcpkg_files = toolchain.default_info.files.to_list()
    if not vcpkg_files:
        fail("vcpkg_install: resolved vcpkg toolchain has no files.")
    vcpkg_cli = vcpkg_files[0]
    # When `allow_network` is on: the x-script mirror handles pre-captured
    # assets first, but on miss vcpkg falls through to the origin URL
    # (achieved by omitting `x-block-origin`). Off (default): block origin
    # to keep the action fully hermetic.
    if ctx.attr.allow_network:
        asset_sources = "x-script,$$EXT_BUILD_ROOT$$/{} {{sha512}} {{url}} {{dst}}".format(serve_script.path)
    else:
        asset_sources = "x-block-origin;x-script,$$EXT_BUILD_ROOT$$/{} {{sha512}} {{url}} {{dst}}".format(serve_script.path)
    install_cmd_lines = [
        "\"$SHORT/vcpkg\" install \\",
        "  --x-manifest-root=\"$$EXT_BUILD_ROOT$$/{}\" \\".format(ctx.file.manifest.dirname),
        "  --x-install-root=\"$SHORT/install\" \\",
        "  --x-buildtrees-root=\"$SHORT/buildtrees\" \\",
        "  --x-packages-root=\"$SHORT/packages\" \\",
        "  --downloads-root=\"$SHORT/downloads\" \\",
        "  --x-asset-sources=\"{}\" \\".format(asset_sources),
    ]
    # When a vcpkg_configuration is set, vcpkg auto-loads its overlays;
    # label-declared overlays remain declared inputs (for Bazel dep
    # tracking) but aren't threaded through the CLI.
    if config_file == None:
        for d in overlay_ports_dirs:
            install_cmd_lines.append("  --overlay-ports=\"$$EXT_BUILD_ROOT$$/{}\" \\".format(d))
        for d in overlay_triplets_dirs:
            install_cmd_lines.append("  --overlay-triplets=\"$$EXT_BUILD_ROOT$$/{}\" \\".format(d))
    selected_features = []
    if ctx.attr.features_flag != None:
        selected_features = ctx.attr.features_flag[BuildSettingInfo].value
        unknown = [f for f in selected_features if f not in ctx.attr.declared_features]
        if unknown:
            fail(
                ("vcpkg_install: features {u} were selected via {f} but are " +
                 "not declared in the manifest's `features` block. " +
                 "Declared: {d}.").format(
                    u = unknown,
                    f = ctx.attr.features_flag.label,
                    d = list(ctx.attr.declared_features),
                ),
            )
    for feat in selected_features:
        install_cmd_lines.append("  --x-feature={} \\".format(feat))
    install_cmd_lines.append("  --triplet={}".format(triplet))

    # vcpkg port helpers (e.g. `x_vcpkg_get_python_packages`) build CMake
    # regexes by interpolating the install-tree/downloads paths and then
    # matching them against other paths. Bazel's canonical repo names
    # (`rules_foreign_cc++vcpkg+…`) contain literal `+` characters, which
    # CMake reads as regex meta and rejects with `Nested *?+`. Shortcut
    # around it by symlinking every Bazel-owned path we hand to vcpkg
    # into a per-target `$SHORT` directory under $TMPDIR that has no `+`
    # in its name. Files land in the real Bazel outputs via the symlink;
    # cmake sees a `+`-free string.
    # When the user sets RULES_FOREIGN_CC_VCPKG_EXEC_PREFIX (via
    # --repo_env), $SHORT lives under that prefix so vcpkg's binary
    # cache and downloads persist between builds. Otherwise $SHORT is
    # ephemeral under /tmp and gets removed on exit (no persistence).
    if EXEC_PREFIX:
        short_setup_lines = [
            "mkdir -p \"{}\"".format(EXEC_PREFIX),
            "SHORT=\"$(mktemp -d \"{}/rfcc-vcpkg-XXXXXX\")\"".format(EXEC_PREFIX),
            "export VCPKG_DEFAULT_BINARY_CACHE=\"{}/binary-cache\"".format(EXEC_PREFIX),
            "mkdir -p \"$VCPKG_DEFAULT_BINARY_CACHE\"",
        ]
    else:
        short_setup_lines = [
            "SHORT=\"$(mktemp -d /tmp/rfcc-vcpkg-XXXXXX)\"",
            "trap 'rm -rf \"$SHORT\"' EXIT",
        ]
    user_script_lines = [
        "mkdir -p \"$$EXT_BUILD_ROOT$$/{}/home\"".format(scratch_dir.path),
        "export HOME=\"$$EXT_BUILD_ROOT$$/{}/home\"".format(scratch_dir.path),
    ] + short_setup_lines + [
        "ln -s \"$$EXT_BUILD_ROOT$$/{}\" \"$SHORT/root\"".format(ctx.file.root_file.dirname),
        "ln -s \"$$INSTALLDIR$$\" \"$SHORT/install\"",
        "mkdir -p \"$$EXT_BUILD_ROOT$$/{}/buildtrees\" \"$$EXT_BUILD_ROOT$$/{}/packages\" \"$$EXT_BUILD_ROOT$$/{}/downloads\"".format(scratch_dir.path, scratch_dir.path, scratch_dir.path),
        "ln -s \"$$EXT_BUILD_ROOT$$/{}/buildtrees\" \"$SHORT/buildtrees\"".format(scratch_dir.path),
        "ln -s \"$$EXT_BUILD_ROOT$$/{}/packages\" \"$SHORT/packages\"".format(scratch_dir.path),
        "ln -s \"$$EXT_BUILD_ROOT$$/{}/downloads\" \"$SHORT/downloads\"".format(scratch_dir.path),
        "ln -s \"$$EXT_BUILD_ROOT$$/{}\" \"$SHORT/vcpkg\"".format(vcpkg_cli.path),
        "export VCPKG_ROOT=\"$SHORT/root\"",
        # Force vcpkg to use cmake/ninja/etc from PATH instead of downloading
        # its own into the downloads/ cache.
        "export VCPKG_FORCE_SYSTEM_BINARIES=1",
        "export VCPKG_BAZEL_ASSET_CACHE=\"$$EXT_BUILD_ROOT$$/{}/asset-cache\"".format(scratch_dir.path),
    ] + stage_lines + install_cmd_lines

    declared_inputs_final = declared_inputs + download_files + [serve_script] + vcpkg_files + overlay_inputs
    if config_file != None:
        declared_inputs_final = declared_inputs_final + [config_file]
    inputs = InputFiles(
        headers = [],
        include_dirs = [],
        libs = [],
        tools_files = tools_files_paths,
        ext_build_dirs = [],
        deps_compilation_info = None,
        deps_linking_info = None,
        declared_inputs = declared_inputs_final,
    )

    # vcpkg needs to invoke `git show` against the .git/ inside the root
    # when the manifest carries `builtin-baseline`/`overrides`. Bazel's
    # sandbox materialises action inputs as symlinks under an execroot
    # layout git rejects, so opt out via `no-sandbox`.
    exec_reqs = {"no-sandbox": "1"}
    if ctx.attr.allow_network:
        exec_reqs["requires-network"] = "1"

    foreign_cc_install_action(
        ctx,
        name = ctx.attr.name,
        mnemonic = "VcpkgInstall",
        install_root = install_tree.path,
        declared_outputs = [install_tree, scratch_dir],
        inputs = inputs,
        user_script_lines = user_script_lines,
        data_dependencies = ctx.attr.data + ctx.attr.build_data + ctx.attr.toolchains,
        tools_env = tools_env,
        block_network = not ctx.attr.allow_network,
        extra_execution_requirements = exec_reqs,
    )

    return [DefaultInfo(files = depset([install_tree]))]

_VCPKG_INSTALL_ATTRS = dict(FOREIGN_CC_FRAMEWORK_COMMON_ATTRS)
_VCPKG_INSTALL_ATTRS.update({
    "build_data": attr.label_list(
        doc = "Files needed by this rule only during build time.",
        mandatory = False,
        allow_files = True,
        cfg = "exec",
        default = [],
    ),
    "data": attr.label_list(
        doc = "Files needed by this rule at runtime.",
        mandatory = False,
        allow_files = True,
        cfg = "target",
        default = [],
    ),
    "downloads_by_triplet": attr.string_keyed_label_dict(
        doc = (
            "Per-triplet filegroup containing every asset vcpkg would " +
            "otherwise fetch over the network. Each file's basename is its " +
            "sha512 hex. The active triplet's filegroup is staged into the " +
            "action's scratch dir and served to vcpkg via an x-script asset " +
            "source so the install doesn't hit the network."
        ),
        default = {},
        allow_files = True,
    ),
    "manifest": attr.label(
        doc = (
            "The `vcpkg.json` manifest driving the install. Typically the " +
            "scrubbed copy produced by the module extension (with " +
            "`builtin-baseline` and `overrides` stripped)."
        ),
        allow_single_file = True,
    ),
    "vcpkg_configuration": attr.label(
        doc = (
            "Optional vcpkg-configuration.json. Must live in the same Bazel " +
            "package as `manifest` so vcpkg auto-loads it from the manifest dir."
        ),
        allow_single_file = True,
    ),
    "overlay_ports": attr.label_list(
        doc = "Directories passed to vcpkg as --overlay-ports.",
        allow_files = True,
    ),
    "overlay_triplets": attr.label_list(
        doc = "Directories passed to vcpkg as --overlay-triplets.",
        allow_files = True,
    ),
    "allow_network": attr.bool(
        default = False,
        doc = (
            "Let the install action reach the network. Some ports fetch " +
            "extra assets from their portfile at build time (past what " +
            "our capture pass sees); enabling this lets vcpkg fall back " +
            "to the origin URL when the pre-captured mirror misses. Off " +
            "by default so builds stay hermetic."
        ),
    ),
    "features_flag": attr.label(
        doc = (
            "Optional `string_list_flag` whose value picks the manifest " +
            "features to enable at install time. Set only when the " +
            "manifest declares a top-level `features` block."
        ),
        providers = [BuildSettingInfo],
    ),
    "declared_features": attr.string_list(
        doc = (
            "Feature names declared in the manifest's top-level `features` " +
            "block. Used to validate values coming from `features_flag`."
        ),
    ),
    "root": attr.label(
        doc = (
            "Target whose default outputs are the vcpkg root's tree " +
            "(triplets, scripts, ports, versions, …). Staged into the " +
            "install action's sandbox as vcpkg's `VCPKG_ROOT`."
        ),
    ),
    "root_file": attr.label(
        doc = (
            "The `.vcpkg-root` anchor file inside the vcpkg root. Its " +
            "action-time directory is exported as `VCPKG_ROOT` to the " +
            "install script."
        ),
        allow_single_file = True,
    ),
    "triplet": attr.label(
        doc = (
            "Target providing the vcpkg triplet via VcpkgTripletInfo. " +
            "Defaults to a built-in target that derives the triplet from " +
            "the active Bazel platform via select()."
        ),
        default = _DEFAULT_TRIPLET,
        providers = [VcpkgTripletInfo],
    ),
})

vcpkg_install = rule(
    _vcpkg_install_impl,
    attrs = _VCPKG_INSTALL_ATTRS,
    fragments = CC_EXTERNAL_RULE_FRAGMENTS,
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_foreign_cc//toolchains:m4_toolchain",
        "@rules_foreign_cc//toolchains:make_toolchain",
        "@rules_foreign_cc//toolchains:meson_toolchain",
        "@rules_foreign_cc//toolchains:ninja_toolchain",
        "@rules_foreign_cc//toolchains:cmake_toolchain",
        # "@rules_foreign_cc//toolchains:msbuild_toolchain",
        "@rules_foreign_cc//toolchains:autoconf_toolchain",
        "@rules_foreign_cc//toolchains:automake_toolchain",
        "@rules_foreign_cc//toolchains:pkgconfig_toolchain",
        "@rules_foreign_cc//toolchains:vcpkg_toolchain",
        "@rules_foreign_cc//foreign_cc/private/framework:shell_toolchain",
    ],
)
