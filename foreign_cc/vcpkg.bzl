load(
    "//foreign_cc/private:framework.bzl",
    "CC_EXTERNAL_RULE_FRAGMENTS",
    "FOREIGN_CC_FRAMEWORK_COMMON_ATTRS",
    "InputFiles",
    "foreign_cc_install_action",
)

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
        "install_tree": attr.label(),  # TODO(TheGrizzlyDev): add doc
        "package": attr.string(),  # TODO(TheGrizzlyDev): add doc
    },
)

def _vcpkg_install_impl(ctx):
    install_tree = ctx.actions.declare_directory("%s_install_tree" % ctx.attr.name)

    root_files = ctx.attr.root[DefaultInfo].files.to_list()
    declared_inputs = [ctx.file.manifest] + root_files

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

    user_script_lines = [
        "export VCPKG_ROOT=\"$$EXT_BUILD_ROOT$$/{}\"".format(ctx.file.root_file.dirname),
        "vcpkg install \\",
        "  --x-manifest-root=\"$$EXT_BUILD_ROOT$$/{}\" \\".format(ctx.file.manifest.dirname),
        "  --x-install-root=\"$$INSTALLDIR$$\" \\",
        "  --triplet={}".format(ctx.attr.triplet),
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
    "manifest": attr.label(allow_single_file = True),  # TODO(TheGrizzlyDev): add doc
    "root": attr.label(),  # TODO(TheGrizzlyDev): add doc
    "root_file": attr.label(allow_single_file = True),  # TODO(TheGrizzlyDev): add doc
    "triplet": attr.string(),  # TODO(TheGrizzlyDev): add doc
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
