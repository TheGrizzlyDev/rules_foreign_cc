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

def _resolve_per_triplet(d, triplet):
    """Look up a per-triplet entry from an attr.string_list_dict.

    Exact-match key wins; the empty key "" is the fallback applied when no
    triplet-specific entry exists. Returns [] if neither is present.
    """
    if triplet in d:
        return d[triplet]
    if "" in d:
        return d[""]
    return []

_VCPKG_EXPORT_SCRIPT = r"""#!/usr/bin/env bash
set -euo pipefail

install_tree="$1"
export_dir="$2"
triplet="$3"
package="$4"
base_rel="$5"

shopt -s nullglob
list_candidates=("$install_tree/vcpkg/info/${package}_"*"_${triplet}.list")
if [ ${#list_candidates[@]} -eq 0 ]; then
  echo "vcpkg_export: no .list file for package='$package' triplet='$triplet' in $install_tree/vcpkg/info/" >&2
  exit 1
fi
listfile="${list_candidates[0]}"

mkdir -p "$export_dir"

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

  # Filter: debug builds, tools, shared docs, pkgconfig files.
  # TODO(TheGrizzlyDev): export share/ — vcpkg writes CMake config files
  # there (needed once we wire up find_package-style consumption).
  # TODO(TheGrizzlyDev): export *pkgconfig/* entries for consumers that drive
  # linkage through pkg-config rather than direct -l flags.
  case "$rel" in
    debug/*|tools/*|share/*) continue ;;
    *pkgconfig/*) continue ;;
  esac

  # Only export include/ and lib/ for the simple version.
  # TODO(TheGrizzlyDev): add bin/ for Windows — vcpkg places DLLs there,
  # and the relative-symlink strategy below won't work on Windows either:
  # we'll need junctions or a copy tree.
  case "$rel" in
    include/*|lib/*) ;;
    *) continue ;;
  esac

  target="$export_dir/$rel"
  mkdir -p "$(dirname "$target")"

  # Relative symlink: depth = (slashes in rel) + 1.
  # That many "../" hops from the symlink's directory reach <export_dir>'s
  # parent, from where <base_rel> points at the install_tree.
  slashes="${rel//[^\/]/}"
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

    ctx.actions.run(
        mnemonic = "VcpkgExport",
        executable = script,
        arguments = [
            install_tree.path,
            export_dir.path,
            triplet,
            ctx.attr.package,
            base_rel,
        ],
        inputs = [install_tree],
        outputs = [export_dir],
        progress_message = "vcpkg_export: linking {} ({})".format(ctx.attr.package, triplet),
    )

    # Resolution order for link flags:
    #   1. out_headers_only=True -> no -l flags at all.
    #   2. Any of out_static_libs/out_shared_libs/out_interface_libs set for
    #      the active triplet (or under the "" fallback key) -> use them.
    #   3. Fallback: guess [package] as the single -l<package> name. The
    #      [package] heuristic only matches single-lib packages whose lib
    #      basename equals the package name; everything else requires an
    #      explicit vcpkg.package_override in MODULE.bazel.
    if ctx.attr.out_headers_only:
        link_flags = []
    else:
        explicit_libs = (
            _resolve_per_triplet(ctx.attr.out_static_libs, triplet) +
            _resolve_per_triplet(ctx.attr.out_shared_libs, triplet) +
            _resolve_per_triplet(ctx.attr.out_interface_libs, triplet)
        )
        library_names = explicit_libs if explicit_libs else [ctx.attr.package]
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
        "out_binaries": attr.string_list_dict(
            doc = "Per-triplet binary basenames (forward-compat; not yet used for CcInfo). Key \"\" applies to all triplets.",
            default = {},
        ),
        "out_headers_only": attr.bool(
            doc = "If True, no -l flags are emitted (header-only package).",
            default = False,
        ),
        "out_interface_libs": attr.string_list_dict(
            doc = "Per-triplet interface library basenames (passed as `-l<name>`). Key \"\" applies to all triplets.",
            default = {},
        ),
        "out_shared_libs": attr.string_list_dict(
            doc = "Per-triplet shared library basenames (passed as `-l<name>`). Key \"\" applies to all triplets.",
            default = {},
        ),
        "out_static_libs": attr.string_list_dict(
            doc = "Per-triplet static library basenames (passed as `-l<name>`). Key \"\" applies to all triplets.",
            default = {},
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
