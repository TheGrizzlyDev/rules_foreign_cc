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

    lines = [
        "load(\"@bazel_skylib//rules/directory:directory.bzl\", \"directory\")",
        "load(\"@rules_foreign_cc//foreign_cc:vcpkg.bzl\", \"vcpkg_install\", \"vcpkg_export\")",
        "",
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
        ")",
        "",
    ]
    for pkg in packages:
        block = [
            "vcpkg_export(",
            "    name = \"{}\",".format(pkg),
            "    install_tree = \":{}\",".format(vcpkg_install_target_name),
            "    package = \"{}\",".format(pkg),
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
    }
)