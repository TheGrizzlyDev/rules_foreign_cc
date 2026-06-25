load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("@rules_foreign_cc//toolchains/native_tools:tool_access.bzl", "get_autoconf_data", "get_automake_data", "get_cmake_data", "get_m4_data", "get_make_data", "get_ninja_data", "get_meson_data", "get_pkgconfig_data", "get_msbuild_data")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_common")
load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("//foreign_cc:providers.bzl", "ForeignCcArtifactInfo", "ForeignCcDepsInfo")

def _vcpkg_export_impl(ctx):
    # TODO(TheGrizzlyDev): implement the following:
    #   - set up directory hierarchy like in https://learn.microsoft.com/en-us/vcpkg/reference/installation-tree-layout
    #   - for the given package, run a tool that takes the respective list file and marshals it into a directory structure
    #   - using map_directory, read the list file from the directories created before
    #   - copy/symlink each of the files into their respective folders  
    #   - if map_directory is not supported then re-export files without copying and just add the correct defines and include prefixes
    pass


vcpkg_export = rule(
    _vcpkg_export_impl,
    attrs = {
        "install_tree": attr.label(), # TODO(TheGrizzlyDev): add doc
        "package": attr.string(), # TODO(TheGrizzlyDev): add doc
    }
)

def _vcpkg_install_impl(ctx):
    # cc_toolchain = find_cpp_toolchain(ctx)
    # autoconf_data = get_autoconf_data(ctx)
    # automake_data = get_automake_data(ctx)
    # cmake_data = get_cmake_data(ctx)
    # m4_data = get_m4_data(ctx)
    # make_data = get_make_data(ctx)
    # ninja_data = get_ninja_data(ctx)
    # meson_data = get_meson_data(ctx)
    # pkgconfig_data = get_pkgconfig_data(ctx)
    # msbuild_data = get_msbuild_data(ctx)
    # print(cc_toolchain)
    # print(autoconf_data)
    # print(automake_data)
    # print(cmake_data)
    # print(m4_data)
    # print(make_data)
    # print(ninja_data)
    # print(meson_data)
    # print(pkgconfig_data)
    # print(msbuild_data)
    # use cc_external_rule_impl to build with a PATH that sets up the hermetic version of these toolchains
    install_tree = ctx.actions.declare_directory("%s_install_tree" % ctx.attr.name)
    vcpkg_root_and_config = depset([ctx.file.manifest], transitive=[ctx.attr.root[DefaultInfo].files])
    
    vcpkg_env = {
        "VCPKG_ROOT": ctx.file.root_file.dirname,
    }

    ctx.actions.run(
        outputs=[install_tree],
        inputs=vcpkg_root_and_config,
        use_default_shell_env=True, 
        executable="vcpkg", 
        arguments=[
            "install",
            "--x-manifest-root=" + ctx.file.manifest.dirname,
            "--x-install-root=" + install_tree.path,
            "--triplet=" + ctx.attr.triplet,
        ],
        env=vcpkg_env,
    )

    return DefaultInfo(
        files=depset([install_tree], transitive=[vcpkg_root_and_config])
    )

vcpkg_install = rule(
    _vcpkg_install_impl,
    attrs = {
        "root": attr.label(), # TODO(TheGrizzlyDev): add doc
        "root_file": attr.label(allow_single_file=True), # TODO(TheGrizzlyDev): add doc
        "manifest": attr.label(allow_single_file=True), # TODO(TheGrizzlyDev): add doc
        "triplet": attr.string(), # TODO(TheGrizzlyDev): add doc
    },
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