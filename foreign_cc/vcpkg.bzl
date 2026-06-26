load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_common")
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

_DEFAULT_TRIPLET = Label("//foreign_cc/private/framework:vcpkg_triplet_info")

def _resolve_triplet(ctx):
    triplet = ctx.attr.triplet[VcpkgTripletInfo].triplet
    if not triplet:
        fail(
            "vcpkg: no triplet mapping for the active platform. " +
            "Override `triplet = ...` with a target providing VcpkgTripletInfo " +
            "(see foreign_cc/private/framework/platform.bzl).",
        )
    return triplet

_OVERRIDE_PAYLOAD_FIELDS = (
    "out_static_libs",
    "out_shared_libs",
    "out_interface_libs",
    "out_binaries",
    "out_headers_only",
)

def _resolve_override(override_json, triplet, compilation_mode):
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
    result = {k: best[k] for k in _OVERRIDE_PAYLOAD_FIELDS if k in best}
    result["_mode_scoped"] = best.get("compilation_mode") != None
    return result

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
# vcpkg layout: include/* (release-only), lib/*, share/*, lib/pkgconfig/*,
# debug/lib/*, debug/share/* (rare). Headers are not duplicated under debug/.
classify() {
  local rel="$1"
  if [ "$debug" = "1" ]; then
    case "$rel" in
      include/*) printf '%s' "$rel" ;;
      debug/lib/*) printf '%s' "${rel#debug/}" ;;
      debug/share/*) printf '%s' "${rel#debug/}" ;;
      # Use release-side share/ for CMake config files. Most ports install
      # them only under <triplet>/share/<pkg>/; vcpkg's own debug-vs-release
      # split happens at the lib/binary level, not at the cmake-package level.
      share/*) printf '%s' "$rel" ;;
      *) printf '' ;;
    esac
  else
    case "$rel" in
      include/*|lib/*|share/*) printf '%s' "$rel" ;;
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

  # Tool binaries are never part of CcInfo; skip in either mode.
  case "$rel" in
    tools/*) continue ;;
  esac

  dst="$(classify "$rel")"
  [ -z "$dst" ] && continue

  # TODO(TheGrizzlyDev): add bin/ for Windows — vcpkg places DLLs there,
  # and the relative-symlink strategy below won't work on Windows either:
  # we'll need junctions or a copy tree.

  target="$export_dir/$dst"
  mkdir -p "$(dirname "$target")"

  # Relative symlink: depth = (slashes in dst) + 1.
  # That many "../" hops from the symlink's directory reach <export_dir>'s
  # parent, from where <base_rel> points at the install_tree.
  slashes="${dst//[^\/]/}"
  depth=$((${#slashes} + 1))
  prefix=""
  for ((i=0; i<depth; i++)); do prefix="../$prefix"; done

  ln -sfn "${prefix}${base_rel}/${triplet}/${rel}" "$target"
done < "$listfile"
"""

def _vcpkg_export_impl(ctx):
    install_tree_files = ctx.attr.install_tree[DefaultInfo].files.to_list()
    if len(install_tree_files) != 1:
        fail("vcpkg_export: expected exactly one install_tree directory, got {}".format(len(install_tree_files)))
    install_tree = install_tree_files[0]

    triplet = _resolve_triplet(ctx)

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

    override = _resolve_override(ctx.attr.override_json, triplet, compilation_mode)

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

    # Resolution order for link flags:
    #   1. override entry says out_headers_only=True -> no -l flags.
    #   2. override entry lists out_static/shared/interface libs -> use them.
    #   3. Fallback: guess [package] as the single -l<package> name. The
    #      [package] heuristic only matches single-lib packages whose lib
    #      basename equals the package name; everything else requires a
    #      vcpkg.package_override in MODULE.bazel.
    if override.get("out_headers_only"):
        link_flags = []
    else:
        explicit_libs = (
            override.get("out_static_libs", []) +
            override.get("out_shared_libs", []) +
            override.get("out_interface_libs", [])
        )
        library_names = explicit_libs if explicit_libs else [ctx.attr.package]
        # Heuristic: vcpkg ports conventionally suffix debug libraries with
        # `d` (e.g. `libfmtd.a`, `libbz2d.a`). In debug mode, apply that
        # suffix to lib names that came from the fallback or from a
        # mode-agnostic override entry. Mode-scoped entries
        # (`compilation_mode = "dbg"`) are taken verbatim — they're the
        # explicit override for packages that don't follow the convention.
        if debug and not override.get("_mode_scoped"):
            library_names = [n + "d" for n in library_names]
        link_flags = ["-L" + export_dir.path + "/lib"] + ["-l" + n for n in library_names]

    compilation_context = cc_common.create_compilation_context(
        headers = depset([export_dir]),
        system_includes = depset([export_dir.path + "/include"]),
        defines = depset(ctx.attr.defines),
    )

    linking_context = cc_common.create_linking_context(
        linker_inputs = depset([
            cc_common.create_linker_input(
                owner = ctx.label,
                user_link_flags = depset(link_flags),
                additional_inputs = depset([export_dir]),
            ),
        ]),
    )

    dep_cc_infos = [dep[CcInfo] for dep in ctx.attr.deps]
    merged = cc_common.merge_cc_infos(cc_infos = [
        CcInfo(compilation_context = compilation_context, linking_context = linking_context),
    ] + dep_cc_infos)

    return [
        DefaultInfo(files = depset([export_dir])),
        merged,
    ]

vcpkg_export = rule(
    _vcpkg_export_impl,
    attrs = {
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
                "`compilation_mode` fields; the most-specific match wins."
            ),
            default = "",
        ),
        "package": attr.string(
            doc = "vcpkg package name to export from the install tree.",
            mandatory = True,
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
    },
    provides = [CcInfo],
)

def _vcpkg_install_impl(ctx):
    install_tree = ctx.actions.declare_directory("%s_install_tree" % ctx.attr.name)

    home_info = ctx.attr.home[DirectoryInfo]
    home_path = home_info.path
    home_inputs = home_info.transitive_files.to_list()

    root_files = ctx.attr.root[DefaultInfo].files.to_list()
    declared_inputs = [ctx.file.manifest] + home_inputs + root_files

    inputs = InputFiles(
        headers = [],
        include_dirs = [],
        libs = [],
        tools_files = [],
        ext_build_dirs = [],
        deps_compilation_info = None,
        deps_linking_info = None,
        declared_inputs = declared_inputs,
    )

    triplet = _resolve_triplet(ctx)

    # TODO(TheGrizzlyDev): support --overlay-ports and --overlay-triplets, with
    # the directories staged into the install action's sandbox. Triplets
    # discovered via overlay_triplets should also be valid keys for
    # vcpkg.triplet_mapping.
    user_script_lines = [
        "export HOME=\"$$EXT_BUILD_ROOT$$/{}\"".format(home_path),
        "export VCPKG_ROOT=\"$$EXT_BUILD_ROOT$$/{}\"".format(ctx.file.root_file.dirname),
        "vcpkg install \\",
        "  --x-manifest-root=\"$$EXT_BUILD_ROOT$$/{}\" \\".format(ctx.file.manifest.dirname),
        "  --x-install-root=\"$$INSTALLDIR$$\" \\",
        "  --triplet={}".format(triplet),
    ]

    foreign_cc_install_action(
        ctx,
        name = ctx.attr.name,
        mnemonic = "VcpkgInstall",
        install_root = install_tree.path,
        declared_outputs = [install_tree],
        inputs = inputs,
        user_script_lines = user_script_lines,
        data_dependencies = ctx.attr.data + ctx.attr.build_data + ctx.attr.toolchains,
        block_network = False,
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
    # TODO(TheGrizzlyDev): move this directory inside the rule so callers
    # don't have to know it exists. Today the generated repo emits a separate
    # `directory(name = "install_tree_home", srcs = [])` target and wires it
    # in via this attr — the indirection is load-bearing but not obvious.
    "home": attr.label(
        doc = "A `bazel_skylib` `directory` target used as $HOME for the vcpkg invocation.",
        mandatory = True,
        providers = [DirectoryInfo],
    ),
    "manifest": attr.label(allow_single_file = True),  # TODO(TheGrizzlyDev): add doc
    "root": attr.label(),  # TODO(TheGrizzlyDev): add doc
    "root_file": attr.label(allow_single_file = True),  # TODO(TheGrizzlyDev): add doc
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
        "@rules_foreign_cc//toolchains:cmake_toolchain",
        "@rules_foreign_cc//toolchains:ninja_toolchain",
        "@rules_foreign_cc//toolchains:cmake_toolchain",
        # "@rules_foreign_cc//toolchains:msbuild_toolchain",
        "@rules_foreign_cc//toolchains:autoconf_toolchain",
        "@rules_foreign_cc//toolchains:automake_toolchain",
        "@rules_foreign_cc//toolchains:pkgconfig_toolchain",
        "@rules_foreign_cc//foreign_cc/private/framework:shell_toolchain",
    ],
)
