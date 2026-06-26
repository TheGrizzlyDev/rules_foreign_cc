load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_common")
load(
    "//foreign_cc:providers.bzl",
    "ForeignCcArtifactInfo",
    "ForeignCcDepsInfo",
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
    "get_cmake_data",
    "get_make_data",
    "get_ninja_data",
    "get_pkgconfig_data",
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

    return [
        DefaultInfo(files = depset([export_dir])),
        merged,
        ForeignCcDepsInfo(artifacts = depset(
            direct = [own_artifact],
            transitive = transitive_artifacts,
        )),
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
    # Action-private scratch for vcpkg's mutable directories (buildtrees,
    # packages, downloads). Keeps the vcpkg root archive immutable so
    # concurrent actions don't fight over `buildtrees/vcpkg-running.lock`.
    scratch_dir = ctx.actions.declare_directory("%s_vcpkg_scratch" % ctx.attr.name)

    home_info = ctx.attr.home[DirectoryInfo]
    home_path = home_info.path
    home_inputs = home_info.transitive_files.to_list()

    root_files = ctx.attr.root[DefaultInfo].files.to_list()

    tools_data = [
        get_cmake_data(ctx),
        get_ninja_data(ctx),
        get_make_data(ctx),
        get_pkgconfig_data(ctx),
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

    declared_inputs = [ctx.file.manifest] + home_inputs + root_files + tools_files_inputs

    triplet = _resolve_triplet(ctx)

    # TODO(TheGrizzlyDev): support --overlay-ports and --overlay-triplets, with
    # the directories staged into the install action's sandbox. Triplets
    # discovered via overlay_triplets should also be valid keys for
    # vcpkg.triplet_mapping.
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

    user_script_lines = [
        "export HOME=\"$$EXT_BUILD_ROOT$$/{}\"".format(home_path),
        "export VCPKG_ROOT=\"$$EXT_BUILD_ROOT$$/{}\"".format(ctx.file.root_file.dirname),
        # Force vcpkg to use cmake/ninja/etc from PATH instead of downloading
        # its own into the downloads/ cache.
        "export VCPKG_FORCE_SYSTEM_BINARIES=1",
        "export VCPKG_BAZEL_ASSET_CACHE=\"$$EXT_BUILD_ROOT$$/{}/asset-cache\"".format(scratch_dir.path),
    ] + stage_lines + [
        "vcpkg install \\",
        "  --x-manifest-root=\"$$EXT_BUILD_ROOT$$/{}\" \\".format(ctx.file.manifest.dirname),
        "  --x-install-root=\"$$INSTALLDIR$$\" \\",
        "  --x-buildtrees-root=\"$$EXT_BUILD_ROOT$$/{}/buildtrees\" \\".format(scratch_dir.path),
        "  --x-packages-root=\"$$EXT_BUILD_ROOT$$/{}/packages\" \\".format(scratch_dir.path),
        "  --downloads-root=\"$$EXT_BUILD_ROOT$$/{}/downloads\" \\".format(scratch_dir.path),
        "  --x-asset-sources=\"x-block-origin;x-script,$$EXT_BUILD_ROOT$$/{} {{sha512}} {{url}} {{dst}}\" \\".format(serve_script.path),
        "  --triplet={}".format(triplet),
    ]

    declared_inputs_final = declared_inputs + download_files + [serve_script]
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
        block_network = True,
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
