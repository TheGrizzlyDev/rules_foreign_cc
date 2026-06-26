"""Entry point for extensions used by bzlmod."""

load("@bazel_features//:features.bzl", "bazel_features")
load("//foreign_cc:repositories.bzl", "rules_foreign_cc_dependencies")
load("//toolchains:prebuilt_toolchains.bzl", "prebuilt_toolchains")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_DEFAULT_CMAKE_VERSION = "3.31.12"
_DEFAULT_NINJA_VERSION = "1.13.2"

cmake_toolchain_version = tag_class(attrs = {
    "version": attr.string(doc = "The cmake version", default = _DEFAULT_CMAKE_VERSION),
})

ninja_toolchain_version = tag_class(attrs = {
    "version": attr.string(doc = "The ninja version", default = _DEFAULT_NINJA_VERSION),
})

def _init(module_ctx):
    rules_foreign_cc_dependencies(
        register_toolchains = False,
        register_built_tools = True,
        register_default_tools = False,
        register_preinstalled_tools = False,
        register_built_pkgconfig_toolchain = True,
        # These should be registered via bzlmod entries instead
        register_repos = False,
    )

    versions = {
        "cmake": _DEFAULT_CMAKE_VERSION,
        "ninja": _DEFAULT_NINJA_VERSION,
    }

    for mod in module_ctx.modules:
        if not mod.is_root:
            for toolchain in mod.tags.cmake:
                versions["cmake"] = toolchain.version

            for toolchain in mod.tags.ninja:
                versions["ninja"] = toolchain.version

    prebuilt_toolchains(
        cmake_version = versions["cmake"],
        ninja_version = versions["ninja"],
        register_toolchains = False,
    )

    if bazel_features.external_deps.extension_metadata_has_reproducible:
        return module_ctx.extension_metadata(reproducible = True)
    else:
        return None

tools = module_extension(
    implementation = _init,
    tag_classes = {
        "cmake": cmake_toolchain_version,
        "ninja": ninja_toolchain_version,
    },
)

# TODO(TheGrizzlyDev): split the code below
# TODO(TheGrizzlyDev): install vcpkg, patchelf hermetically
# TODO(TheGrizzlyDev): add doc
_OVERRIDE_DICT_FIELDS = (
    "out_static_libs",
    "out_shared_libs",
    "out_interface_libs",
    "out_binaries",
)

def _render_string_list_dict(d):
    # Render a {triplet: [name, ...]} dict as the Starlark literal for a
    # vcpkg_export(...) kwarg. Skips empty value lists. Returns None if there
    # is no non-empty entry, so the caller can omit the kwarg entirely.
    items = []
    for triplet in sorted(d.keys()):
        values = d[triplet]
        if not values:
            continue
        rendered = ", ".join(["\"{}\"".format(v) for v in values])
        items.append("        \"{}\": [{}],".format(triplet, rendered))
    if not items:
        return None
    return ["{"] + items + ["    }"]

def _vcpkg_repo_impl(repo_ctx):
    vcpkg_install_target_name = "install_tree"

    manifest_path = repo_ctx.path(repo_ctx.attr.manifest)
    manifest = json.decode(repo_ctx.read(manifest_path))
    packages = []
    for dep in manifest.get("dependencies", []):
        if type(dep) == "string":
            packages.append(dep)
        else:
            packages.append(dep["name"])

    overrides_by_pkg = {}
    for ov in json.decode(repo_ctx.attr.overrides_json):
        overrides_by_pkg[ov["package"]] = ov

    triplet_mappings = json.decode(repo_ctx.attr.triplet_mappings_json)

    # Emit one config_setting per unique constraint set. Two mappings that
    # share a constraint set but resolve to different triplets are an
    # ambiguity the user must resolve — fail eagerly with the list.
    config_setting_for = {}  # constraint-set tuple -> config_setting name
    triplet_for_key = {}     # constraint-set tuple -> triplet name (for dup check)
    config_setting_blocks = []
    triplet_select = {}
    triplet_select_keys = []  # preserve insertion order for stable BUILD
    for tm in triplet_mappings:
        key = tuple(tm["constraints"])
        if key in triplet_for_key:
            if triplet_for_key[key] != tm["triplet"]:
                fail(
                    "vcpkg: multiple triplet_mapping tags share constraints " +
                    "{} but resolve to different triplets: {} and {}.".format(
                        list(key),
                        triplet_for_key[key],
                        tm["triplet"],
                    ),
                )
            continue
        triplet_for_key[key] = tm["triplet"]
        name = "_triplet_mapping_{}".format(len(config_setting_for))
        config_setting_for[key] = name
        config_setting_blocks += [
            "config_setting(",
            "    name = \"{}\",".format(name),
            "    constraint_values = [",
        ] + [
            "        \"{}\",".format(c) for c in tm["constraints"]
        ] + [
            "    ],",
            ")",
            "",
        ]
        label = ":" + name
        triplet_select_keys.append(label)
        triplet_select[label] = tm["triplet"]

    triplet_info_target = "vcpkg_triplet_info"
    triplet_info_blocks = [
        "vcpkg_triplet_info_from_mappings(",
        "    name = \"{}\",".format(triplet_info_target),
        "    mapping = {",
    ] + [
        "        \"{}\": \"{}\",".format(label, triplet_select[label]) for label in triplet_select_keys
    ] + [
        "    },",
        ")",
        "",
    ]

    lines = [
        "load(\"@bazel_skylib//rules/directory:directory.bzl\", \"directory\")",
        "load(\"@rules_foreign_cc//foreign_cc:vcpkg.bzl\", \"vcpkg_install\", \"vcpkg_export\")",
        "load(\"@rules_foreign_cc//foreign_cc/private/framework:platform.bzl\", \"vcpkg_triplet_info_from_mappings\")",
        "",
    ] + config_setting_blocks + triplet_info_blocks + [
        "directory(",
        "    name = \"{}_home\",".format(vcpkg_install_target_name),
        "    srcs = [],",
        ")",
        "",
        "vcpkg_install(",
        "    name = \"{}\",".format(vcpkg_install_target_name),
        "    root = \"@{}//:srcs\",".format(repo_ctx.attr.vcpkg_root),
        "    root_file = \"@{}//:.vcpkg-root\",".format(repo_ctx.attr.vcpkg_root),
        "    manifest = \"{}\",".format(repo_ctx.attr.manifest),
        "    home = \":{}_home\",".format(vcpkg_install_target_name),
        "    triplet = \":{}\",".format(triplet_info_target),
        ")",
        "",
    ]
    for pkg in packages:
        block = [
            "vcpkg_export(",
            "    name = \"{}\",".format(pkg),
            "    install_tree = \":{}\",".format(vcpkg_install_target_name),
            "    package = \"{}\",".format(pkg),
            "    triplet = \":{}\",".format(triplet_info_target),
        ]

        ov = overrides_by_pkg.get(pkg)
        if ov:
            for field in _OVERRIDE_DICT_FIELDS:
                rendered = _render_string_list_dict(ov.get(field) or {})
                if rendered:
                    # rendered is ["{", "        \"\": [...],", ..., "    }"]
                    block.append("    {} = {}".format(field, rendered[0]))
                    block += rendered[1:-1]
                    block.append("    {},".format(rendered[-1]))
            if ov.get("out_headers_only"):
                block.append("    out_headers_only = True,")

        block += [
            "    visibility = [\"//visibility:public\"],",
            ")",
            "",
        ]
        lines += block

    repo_ctx.file("BUILD", "\n".join(lines))

vcpkg_repo = repository_rule(
    implementation = _vcpkg_repo_impl,
    attrs = {
        "manifest": attr.label(allow_single_file=True), # TODO(TheGrizzlyDev): add doc
        "overrides_json": attr.string(
            default = "[]",
            doc = "JSON-encoded list of per-package override dicts. See vcpkg.package_override.",
        ),
        "triplet_mappings_json": attr.string(
            default = "[]",
            doc = "JSON-encoded list of {constraints, triplet} dicts. See vcpkg.triplet_mapping.",
        ),
        "vcpkg_root": attr.string(mandatory = True), # TODO(TheGrizzlyDev): add doc
    }
)

DEFAULT_VCPKG_ROOT_WORKSPACE_NAME = "default_vcpkg_root"

vcpkg_root_http_archive = tag_class(attrs = {
    "name": attr.string(default = DEFAULT_VCPKG_ROOT_WORKSPACE_NAME), # TODO(TheGrizzlyDev): add doc
    "urls": attr.string_list(mandatory = True), # TODO(TheGrizzlyDev): add doc
    "sha256": attr.string(), # TODO(TheGrizzlyDev): add doc
    "strip_prefix": attr.string(), # TODO(TheGrizzlyDev): add doc
})

vcpkg_source = tag_class(attrs = {
    "name": attr.string(doc = "The name of the workspace generated"),
    "manifest": attr.label(default = "@__main__//:vcpkg.json", allow_single_file=True), # TODO(TheGrizzlyDev): add doc
    "root": attr.string(default = DEFAULT_VCPKG_ROOT_WORKSPACE_NAME) # TODO(TheGrizzlyDev): add doc
})

# TODO(TheGrizzlyDev): add doc — per-package output overrides spliced onto the
# generated vcpkg_export(...) calls. Mirrors the out_* attrs on vcpkg_export.
# Each tag carries content for a single triplet (or "" == all triplets). Tags
# for the same (source, package) merge into per-triplet dicts.
# Built-in triplet mappings shipped with rules_foreign_cc. A default mapping is
# dropped if any user mapping's constraint set is a superset of (or equal to)
# the default's set — so a user can shadow `[cpu:x86_64, os:windows] →
# x64-windows` with their own mapping for the same cell, while a strictly
# more-specific user mapping coexists with the default.
_DEFAULT_TRIPLET_MAPPINGS = [
    {"constraints": ["@platforms//cpu:x86_64",  "@platforms//os:linux"],   "triplet": "x64-linux"},
    {"constraints": ["@platforms//cpu:aarch64", "@platforms//os:linux"],   "triplet": "arm64-linux"},
    {"constraints": ["@platforms//cpu:x86_64",  "@platforms//os:macos"],   "triplet": "x64-osx"},
    {"constraints": ["@platforms//cpu:aarch64", "@platforms//os:macos"],   "triplet": "arm64-osx"},
    {"constraints": ["@platforms//cpu:x86_64",  "@platforms//os:windows"], "triplet": "x64-windows"},
    {"constraints": ["@platforms//cpu:x86_32",  "@platforms//os:windows"], "triplet": "x86-windows"},
    {"constraints": ["@platforms//cpu:aarch64", "@platforms//os:windows"], "triplet": "arm64-windows"},
]

# User-declared triplet mapping. Materialized as a config_setting in the
# generated @vcpkg_deps repo and woven into the single select() that drives
# the per-source vcpkg_triplet_info target.
vcpkg_triplet_mapping = tag_class(attrs = {
    "constraints": attr.label_list(
        doc = "Constraint value labels (e.g. @platforms//os:linux). Materialized " +
              "as the config_setting's constraint_values list.",
        mandatory = True,
    ),
    "triplet": attr.string(
        doc = "vcpkg triplet name to resolve to when all `constraints` hold.",
        mandatory = True,
    ),
})

vcpkg_package_override = tag_class(attrs = {
    "source": attr.string(
        doc = "The name of the vcpkg.source repo these overrides apply to.",
        mandatory = True,
    ),
    "package": attr.string(
        doc = "vcpkg package name to override.",
        mandatory = True,
    ),
    "triplet": attr.string(
        doc = "If non-empty, restricts the override to this triplet. Empty == all triplets.",
        default = "",
    ),
    "out_static_libs": attr.string_list(default = []),
    "out_shared_libs": attr.string_list(default = []),
    "out_interface_libs": attr.string_list(default = []),
    "out_binaries": attr.string_list(default = []),
    "out_headers_only": attr.bool(default = False),
})

VCPKG_ROOT_BUILD_FILE = """
exports_files([".vcpkg-root"])

filegroup(
    name = "srcs", 
    srcs=glob(["**/*"]),
    visibility = ["//visibility:public"],
)
""".strip()

def _vcpkg_mod(module_ctx):
    default_root_configured = False
    
    vcpkg_repo_name = lambda name: "vcpkg_root_%s" % (name)
    
    for mod in module_ctx.modules:
        for root_tag in mod.tags.vcpkg_root_http_archive:
            name = root_tag.name
            if name == DEFAULT_VCPKG_ROOT_WORKSPACE_NAME:
                default_root_configured = True
            
            http_archive(
                name = vcpkg_repo_name(name),
                urls = root_tag.urls,
                sha256 = root_tag.sha256,
                strip_prefix = root_tag.strip_prefix,
                build_file_content = VCPKG_ROOT_BUILD_FILE,
            )
            
    if not default_root_configured:
        http_archive(
            name = vcpkg_repo_name(DEFAULT_VCPKG_ROOT_WORKSPACE_NAME),
            urls = ["https://github.com/microsoft/vcpkg/archive/refs/tags/2026.06.01.tar.gz"],
            strip_prefix = "vcpkg-2026.06.01",
            sha256 = "d394626f9205790915c70e1281eb08554e8d72ac0677334893e32636ae08ec3d",
            build_file_content = VCPKG_ROOT_BUILD_FILE,
        )
        
    # Aggregate overrides per (source.name, package) into per-triplet dicts.
    # Each tag with `triplet = "x"` becomes one entry under key "x"; a tag
    # with no `triplet` becomes the "" (fallback) key. Multiple tags for the
    # same (source, package, triplet) overlay (last writer wins per field).
    overrides_by_source = {}
    for mod in module_ctx.modules:
        for ov in mod.tags.package_override:
            by_pkg = overrides_by_source.setdefault(ov.source, {})
            entry = by_pkg.setdefault(ov.package, {
                "package": ov.package,
                "out_static_libs": {},
                "out_shared_libs": {},
                "out_interface_libs": {},
                "out_binaries": {},
                "out_headers_only": False,
            })
            for field in ("out_static_libs", "out_shared_libs", "out_interface_libs", "out_binaries"):
                values = getattr(ov, field)
                if values:
                    entry[field][ov.triplet] = list(values)
            if ov.out_headers_only:
                entry["out_headers_only"] = True

    # Collect user-declared triplet mappings globally (across modules).
    # Stringifying a Label yields the canonical apparent-repo form
    # (e.g. "@@platforms//os:macos"), so we use that consistently on both
    # the user and default paths to make subset comparisons reliable.
    user_mappings = []
    for mod in module_ctx.modules:
        for tm in mod.tags.triplet_mapping:
            user_mappings.append({
                "constraints": sorted([str(c) for c in tm.constraints]),
                "triplet": tm.triplet,
            })

    # Drop built-in defaults whose constraint set is a (non-strict) subset of
    # any user mapping's constraint set. That's the "user wins on the same
    # cell" rule. More-specific user mappings (strict supersets) leave the
    # default in place; select()'s most-specific-wins handles them at analysis.
    user_constraint_sets = [{c: True for c in um["constraints"]} for um in user_mappings]
    default_mappings = []
    for dm in _DEFAULT_TRIPLET_MAPPINGS:
        canonical = sorted([str(Label(c)) for c in dm["constraints"]])
        dm_set = {c: True for c in canonical}
        shadowed = False
        for us in user_constraint_sets:
            if all([c in us for c in dm_set]):
                shadowed = True
                break
        if not shadowed:
            default_mappings.append({"constraints": canonical, "triplet": dm["triplet"]})

    triplet_mappings = user_mappings + default_mappings

    for mod in module_ctx.modules:
        for source in mod.tags.source:
            applicable = []
            by_pkg = overrides_by_source.get(source.name, {})
            for pkg in sorted(by_pkg.keys()):
                applicable.append(by_pkg[pkg])

            vcpkg_repo(
                name = source.name,
                manifest = source.manifest,
                vcpkg_root = vcpkg_repo_name(source.root),
                overrides_json = json.encode(applicable),
                triplet_mappings_json = json.encode(triplet_mappings),
            )
    return None

# TODO(TheGrizzlyDev): add support for the configuration file: https://learn.microsoft.com/en-us/vcpkg/reference/vcpkg-configuration-json
# TODO(TheGrizzlyDev): automatically use the right triplet for a given platform
vcpkg = module_extension(
    implementation = _vcpkg_mod,
    tag_classes = {
        "vcpkg_root_http_archive": vcpkg_root_http_archive,
        "source": vcpkg_source,
        "package_override": vcpkg_package_override,
        "triplet_mapping": vcpkg_triplet_mapping,
    }
)