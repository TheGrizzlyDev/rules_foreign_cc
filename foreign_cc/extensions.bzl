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
# TODO(TheGrizzlyDev): install cmake, vcpkg, patchelf hermetically
# TODO(TheGrizzlyDev): add doc
def _vcpkg_repo_impl(repo_ctx):
    manifest_path = repo_ctx.path(repo_ctx.attr.manifest)
    repo_ctx.watch(manifest_path)
    repo_ctx.symlink(manifest_path, "vcpkg.json")
    
    vcpkg_root_doc = repo_ctx.path(repo_ctx.attr.vcpkg_root)
    vcpkg_root_dir = vcpkg_root_doc.dirname # Gets the root directory containing the file .vcpkg-root AKA the actual vcpkg root directory

    triplet = repo_ctx.attr.triplet
    vcpkg_env = {
        "VCPKG_ROOT": str(vcpkg_root_dir),
    }
    vcpkg_install = repo_ctx.execute([
            "vcpkg", "install",
            "--x-install-root=vcpkg_installed",
            "--triplet=" + triplet
        ],
        environment = vcpkg_env
    )

    if vcpkg_install.return_code != 0:
        fail("vcpkg install failed: %s" % vcpkg_install.stderr)

    # list_packages = repo_ctx.execute([
    #     "ls", "-lisa", "vcpkg_installed/vcpkg/",
    # ])
    # print(list_packages.stdout)

    # print(repo_ctx.read("vcpkg_installed/vcpkg/vcpkg-running.lock"))
    # print(repo_ctx.read("vcpkg_installed/vcpkg/info/fmt_12.1.0_arm64-osx.list"))


    vcpkg_list_installed_packages = repo_ctx.execute([
            "vcpkg", "list",
            "--x-install-root=vcpkg_installed"
        ],
        environment = vcpkg_env)
    
    if vcpkg_list_installed_packages.return_code != 0:
        fail("Failed to query installed vcpkg packages: %s" % vcpkg_list_installed_packages.stderr)

    packages = []
    for line in vcpkg_list_installed_packages.stdout.splitlines():
        parts = line.strip().split(' ', 1)
        if len(parts) < 2:
            continue  # Skip malformed or empty lines
        line = parts[1]
            
        pkg_and_triplet = parts[0].split(":")
        pkg_name = pkg_and_triplet[0]
        triplet = pkg_and_triplet[1]
        
        version = line.strip().split(' ', 1)[0]

        packages.append((pkg_name, triplet, version))

    build_file_content = """
load("@rules_cc//cc:defs.bzl", "cc_import")
    """
    def generate_targets(pkg_name, files):
        into_literal_starlark_list = lambda l: "[%s]" % (",".join(["\"%s\"" % (v) for v in l]))
        return """
filegroup(
    name = "{pkg_name}_data",
    srcs = {files_list},
)
    """.format(
        pkg_name=pkg_name,
        files_list=into_literal_starlark_list([f for f in files if not f.endswith("/")]),
    )

    for package in packages:
        print("Found package: ", package)
        pkg_name = package[0]
        triplet = package[1]
        version = package[2]
        pkg_list = repo_ctx.read("vcpkg_installed/vcpkg/info/{pkg_name}_{version}_{triplet}.list".format(
            pkg_name=pkg_name,
            triplet=triplet,
            version=version,
        )).splitlines()

        files = ["vcpkg_installed/%s" % (file) for file in pkg_list]

        build_file_content += generate_targets(pkg_name, files)

    print(build_file_content)
    repo_ctx.file("BUILD", build_file_content)


vcpkg_repo = repository_rule(
    implementation = _vcpkg_repo_impl,
    attrs = {
        "manifest": attr.label(default = "//:vcpkg.json", allow_single_file=True), # TODO(TheGrizzlyDev): add doc
        "triplet": attr.string(), # TODO(TheGrizzlyDev): add doc
        "vcpkg_root": attr.label(mandatory = True), # TODO(TheGrizzlyDev): add doc
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
    "manifest": attr.label(default = "//:vcpkg.json", allow_single_file=True), # TODO(TheGrizzlyDev): add doc
    "triplet": attr.string(), # TODO(TheGrizzlyDev): add doc
    "root": attr.string(default = DEFAULT_VCPKG_ROOT_WORKSPACE_NAME) # TODO(TheGrizzlyDev): add doc
})

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
                build_file_content = "exports_files(glob(['**']))",
            )
            
    if not default_root_configured:
        http_archive(
            name = vcpkg_repo_name(DEFAULT_VCPKG_ROOT_WORKSPACE_NAME),
            urls = ["https://github.com/microsoft/vcpkg/archive/refs/tags/2026.06.01.tar.gz"],
            strip_prefix = "vcpkg-2026.06.01",
            sha256 = "d394626f9205790915c70e1281eb08554e8d72ac0677334893e32636ae08ec3d",
            build_file_content = "exports_files(glob(['**']))",
        )
        
    for mod in module_ctx.modules:
        for source in mod.tags.source:
            target_root_repo = vcpkg_repo_name(source.root)
            
            vcpkg_repo(
                name = source.name,
                manifest = source.manifest,
                triplet = source.triplet,
                vcpkg_root = "@{}//:.vcpkg-root".format(target_root_repo),
            )
    return None

vcpkg = module_extension(
    implementation = _vcpkg_mod,
    tag_classes = {
        "vcpkg_root_http_archive": vcpkg_root_http_archive,
        "source": vcpkg_source,
    }
)