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
def _vcpkg_repo_impl(repo_ctx):
    vcpkg_install_target_name = "install_tree"

    build_file_content_template = """
load("@rules_foreign_cc//foreign_cc:vcpkg.bzl", "vcpkg_install", "vcpkg_export")

vcpkg_install(
    name = "{vcpkg_install_target_name}",
    root = "@{vcpkg_root}//:srcs",
    root_file = "@{vcpkg_root}//:.vcpkg-root",
    manifest = "{manifest}",
    triplet = "{triplet}",
)
    """

    # TODO(TheGrizzlyDev): parse vcpkg.json to list all the packages. For each of them, create a vcpkg_export target

    build_file_content = build_file_content_template.format(
        vcpkg_install_target_name=vcpkg_install_target_name,
        vcpkg_root=repo_ctx.attr.vcpkg_root,
        manifest=repo_ctx.attr.manifest,
        triplet=repo_ctx.attr.triplet,
    )
    print(build_file_content)
    repo_ctx.file("BUILD", build_file_content)

vcpkg_repo = repository_rule(
    implementation = _vcpkg_repo_impl,
    attrs = {
        "manifest": attr.label(allow_single_file=True), # TODO(TheGrizzlyDev): add doc
        "triplet": attr.string(), # TODO(TheGrizzlyDev): add doc
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
    "triplet": attr.string(), # TODO(TheGrizzlyDev): add doc
    "root": attr.string(default = DEFAULT_VCPKG_ROOT_WORKSPACE_NAME) # TODO(TheGrizzlyDev): add doc
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
        
    for mod in module_ctx.modules:
        for source in mod.tags.source:
            vcpkg_repo(
                name = source.name,
                manifest = source.manifest,
                triplet = source.triplet,
                vcpkg_root = vcpkg_repo_name(source.root),
            )
    return None

# TODO(TheGrizzlyDev): add support for the configuration file: https://learn.microsoft.com/en-us/vcpkg/reference/vcpkg-configuration-json
# TODO(TheGrizzlyDev): automatically use the right triplet for a given platform
vcpkg = module_extension(
    implementation = _vcpkg_mod,
    tag_classes = {
        "vcpkg_root_http_archive": vcpkg_root_http_archive,
        "source": vcpkg_source,
    }
)