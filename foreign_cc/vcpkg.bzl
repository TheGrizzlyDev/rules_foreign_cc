load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")

def _update_lock_file_impl(ctx):
    pass


update_lock_file = rule(
    _update_lock_file_impl,
    executable=True,
    attrs = {
    }
)

def _vcpkg_export_impl(ctx):
    pass


vcpkg_export = rule(
    _vcpkg_export_impl,
    attrs = {
    }
)

def _vcpkg_install_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
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
        "manifest_lock": attr.label(allow_single_file=True), # TODO(TheGrizzlyDev): add doc
        "triplet": attr.string(), # TODO(TheGrizzlyDev): add doc
    },
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_foreign_cc//toolchains:meson_toolchain",
        "@rules_foreign_cc//toolchains:cmake_toolchain",
        "@rules_foreign_cc//toolchains:ninja_toolchain",
        "@rules_foreign_cc//toolchains:pkgconfig_toolchain",
        "@rules_foreign_cc//toolchains:make_toolchain",
        "@rules_foreign_cc//foreign_cc/private/framework:shell_toolchain",
        "@rules_foreign_cc//toolchains:cmake_toolchain",
        "@rules_foreign_cc//toolchains:m4_toolchain",
    ],
)