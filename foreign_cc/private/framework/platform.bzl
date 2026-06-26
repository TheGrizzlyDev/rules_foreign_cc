"""A helper module containing tools for detecting platform information"""

SUPPORTED_CPU = [
    "aarch64",
    "armv7",
    "ppc64le",
    "s390x",
    "wasm32",
    "wasm64",
    "x86_32",
    "x86_64",
]

SUPPORTED_OS = [
    "android",
    "emscripten",
    "freebsd",
    "ios",
    "linux",
    "macos",
    "none",
    "openbsd",
    "qnx",
    "tvos",
    "wasi",
    "watchos",
    "windows",
]

PLATFORM_CONSTRAINTS_RULE_ATTRIBUTES = {
    "_{}_constraint".format(i): attr.label(default = Label("@platforms//os:{}".format(i)))
    for i in SUPPORTED_OS
}

# this would be cleaner as x | y, but that's not supported in bazel 5.4.0
PLATFORM_CONSTRAINTS_RULE_ATTRIBUTES.update({
    "_{}_constraint".format(i): attr.label(default = Label("@platforms//cpu:{}".format(i)))
    for i in SUPPORTED_CPU
})

ForeignCcPlatformInfo = provider(
    doc = "A provider containing information about the current platform",
    fields = {
        "cpu": "The platform cpu",
        "os": "The platform os",
    },
)

def _framework_platform_info_impl(ctx):
    """The implementation of `framework_platform_info`

    Args:
        ctx (ctx): The rule's context object

    Returns:
        list: A provider containing platform info
    """
    return [ForeignCcPlatformInfo(
        os = ctx.attr.os,
        cpu = ctx.attr.cpu,
    )]

_framework_platform_info = rule(
    doc = "A rule defining platform information used by the foreign_cc framework",
    implementation = _framework_platform_info_impl,
    attrs = {
        "cpu": attr.string(
            doc = "The platform's cpu",
        ),
        "os": attr.string(
            doc = "The platform's operating system",
        ),
    },
)

def framework_platform_info(name = "platform_info"):
    """Define a target containing platform information used in the foreign_cc framework

    Args:
      name: A unique name for this target.
    """

    # this would be cleaner as x | y, but that's not supported in bazel 5.4.0
    select_os = {
        "@platforms//os:{}".format(i): i
        for i in SUPPORTED_OS
    }
    select_os.update({
        "//conditions:default": "unknown",
    })

    select_cpu = {
        "@platforms//cpu:{}".format(i): i
        for i in SUPPORTED_CPU
    }
    select_cpu.update({
        "//conditions:default": "unknown",
    })

    _framework_platform_info(
        name = name,
        os = select(select_os),
        cpu = select(select_cpu),
        visibility = ["//visibility:public"],
    )

def os_name(ctx):
    """A helper function for getting the operating system name from a `ForeignCcPlatformInfo` provider

    Args:
        ctx (ctx): The current rule's context object

    Returns:
        str: The string of the current platform
    """
    platform_info = getattr(ctx.attr, "_foreign_cc_framework_platform")
    if not platform_info:
        return "unknown"

    return platform_info[ForeignCcPlatformInfo].os

def arch_name(ctx):
    """A helper function for getting the arch name from a `ForeignCcPlatformInfo` provider

    Args:
        ctx (ctx): The current rule's context object

    Returns:
        str: The string of the current platform
    """
    platform_info = getattr(ctx.attr, "_foreign_cc_framework_platform")
    if not platform_info:
        return "unknown"

    return platform_info[ForeignCcPlatformInfo].cpu

def target_arch_name(ctx):
    """A helper function for getting the target architecture name based on the constraints

    Args:
        ctx (ctx): The current rule's context object

    Returns:
        str: The string of the current platform
    """
    for arch in SUPPORTED_CPU:
        constraint = getattr(ctx.attr, "_{}_constraint".format(arch))
        if constraint and ctx.target_platform_has_constraint(constraint[platform_common.ConstraintValueInfo]):
            return arch

    return "unknown"

def target_os_name(ctx):
    """A helper function for getting the target operating system name based on the constraints

    Args:
        ctx (ctx): The current rule's context object

    Returns:
        str: The string of the current platform
    """
    for os in SUPPORTED_OS:
        constraint = getattr(ctx.attr, "_{}_constraint".format(os))
        if constraint and ctx.target_platform_has_constraint(constraint[platform_common.ConstraintValueInfo]):
            return os

    return "unknown"

VcpkgTripletInfo = provider(
    doc = "vcpkg triplet for the active Bazel target platform",
    fields = {"triplet": "(str) e.g. arm64-osx, x64-linux, x64-windows"},
)

# vcpkg uses `{arch}-{os}` with a simplified vocabulary. Bazel constraints
# map onto these values; combinations not represented here resolve to "" and
# the consuming rule fails with a clear error.
_VCPKG_ARCH = {
    "@platforms//cpu:x86_64": "x64",
    "@platforms//cpu:aarch64": "arm64",
    "@platforms//cpu:x86_32": "x86",
    "@platforms//cpu:armv7": "arm",
}

_VCPKG_OS = {
    "@platforms//os:linux": "linux",
    "@platforms//os:macos": "osx",
    "@platforms//os:windows": "windows",
}

def _vcpkg_triplet_info_impl(ctx):
    if not ctx.attr.arch or not ctx.attr.os:
        return [VcpkgTripletInfo(triplet = "")]
    return [VcpkgTripletInfo(triplet = "{}-{}".format(ctx.attr.arch, ctx.attr.os))]

_vcpkg_triplet_info = rule(
    doc = "Resolves the vcpkg triplet for the active target platform.",
    implementation = _vcpkg_triplet_info_impl,
    attrs = {
        "arch": attr.string(doc = "vcpkg architecture name"),
        "os": attr.string(doc = "vcpkg OS name"),
    },
    provides = [VcpkgTripletInfo],
)

def vcpkg_triplet_info(name = "vcpkg_triplet_info"):
    """Defines a target whose VcpkgTripletInfo is derived from select() over
    @platforms//{cpu,os}:*.

    Users with non-default triplets (e.g. x64-linux-static) can instantiate
    their own _vcpkg_triplet_info-shaped target with a literal triplet string
    and point vcpkg_install/vcpkg_export's `triplet` attr at it.

    Args:
      name: A unique name for this target.
    """
    arch_select = {k: v for k, v in _VCPKG_ARCH.items()}
    arch_select["//conditions:default"] = ""
    os_select = {k: v for k, v in _VCPKG_OS.items()}
    os_select["//conditions:default"] = ""

    _vcpkg_triplet_info(
        name = name,
        arch = select(arch_select),
        os = select(os_select),
        visibility = ["//visibility:public"],
    )

def _vcpkg_triplet_info_from_mappings_impl(ctx):
    if not ctx.attr.triplet:
        fail(
            "vcpkg: no triplet_mapping matches the active Bazel platform. " +
            "Add a vcpkg.triplet_mapping(constraints = [...], triplet = \"...\") " +
            "tag to MODULE.bazel. Known triplets declared so far: {}".format(
                sorted(ctx.attr.known_triplets),
            ),
        )
    return [VcpkgTripletInfo(triplet = ctx.attr.triplet)]

_vcpkg_triplet_info_from_mappings = rule(
    doc = "Resolves a vcpkg triplet from a {config_setting: triplet} mapping.",
    implementation = _vcpkg_triplet_info_from_mappings_impl,
    attrs = {
        "triplet": attr.string(
            doc = "Resolved triplet name. Populated by select() in the macro; " +
                  "empty string means 'no mapping matched the active platform'.",
        ),
        "known_triplets": attr.string_list(
            doc = "All triplet names declared in the mapping. Used only for the " +
                  "fallback error message.",
        ),
    },
    provides = [VcpkgTripletInfo],
)

def vcpkg_triplet_info_from_mappings(name, mapping):
    """Defines a target whose VcpkgTripletInfo is resolved from a
    {config_setting_label: triplet_name} mapping via a single select().

    The default branch returns "" so the rule impl can fail with a built-in
    diagnostic listing the known triplets.

    Args:
      name: A unique name for this target.
      mapping: dict of config_setting label -> vcpkg triplet name.
    """
    select_dict = dict(mapping)
    select_dict["//conditions:default"] = ""
    _vcpkg_triplet_info_from_mappings(
        name = name,
        triplet = select(select_dict),
        known_triplets = sorted({v: None for v in mapping.values()}.keys()),
        visibility = ["//visibility:public"],
    )

def triplet_name(os, arch):
    """A helper function for getting the platform triplet from the results of the above arch/os functions

    Args:
        os (str): the os
        arch (str): the arch

    Returns:
        str: The string of the current platform
    """

    # This is like a simplified config.guess / config.sub from autotools
    if os == "linux":
        # The linux values here were what config.guess returns on ubuntu:22.04;
        # specifically, this version:
        # https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob;f=config.guess;hb=00b15927496058d23e6258a28d8996f87cf1f191
        #
        # bazel doesn't have common libc constraints, which makes it difficult
        # to guess what the correct value for the last field might be (it would
        # be musl on alpine, for example). This doesn't change what the
        # compiler itself will do, though, so as long as we normalize
        # consistently, I don't think this will break alpine.
        if arch == "aarch64":
            return "aarch64-unknown-linux-gnu"
        elif arch == "armv7":
            return "armv7l-unknown-linux-gnueabihf"
        elif arch == "ppc64le":
            return "powerpc64le-unknown-linux-gnu"
        elif arch == "s390x":
            return "s390x-ibm-linux-gnu"
        elif arch == "x86_32":
            return "i686-pc-linux-gnu"
        elif arch == "x86_64":
            return "x86_64-pc-linux-gnu"

    elif os == "macos":
        # These are _not_ what config.guess would return for darwin;
        # config.guess puts the release version (the result of uname -r) in the
        # field, e.g.  darwin23.4.0.
        #
        # The OS field is unnormalized and any dev can write a check that does
        # arbitrary inspection of it. Examples of these:
        # - libffi has a custom macro
        #   (https://github.com/libffi/libffi/blob/8e3ef965c2d0015ed129a06d0f11f30c2120a413/acinclude.m4#L40)
        #   that doesn't handle macos, just darwin, so that's unsafe
        # - some versions of libtool (like this version in the gcc tree:
        #   https://github.com/gcc-mirror/gcc/blob/3f1e15e885185ad63a67c7fe423d2a0b4d8da101/libtool.m4#L1071)
        #   check for darwin2*, not just darwin, so returning it without the version isn't good either.
        #
        # Currently, this returns darwin21, which is Monterey, the current
        # oldest non-eol version of darwin. (You can look that up here:
        # https://en.wikipedia.org/wiki/Darwin_(operating_system)

        if arch == "aarch64":
            return "aarch64-apple-darwin21"
        elif arch == "x86_64":
            return "x86_64-apple-darwin21"

    elif os == "emscripten":
        if arch == "wasm32":
            return "wasm32-unknown-emscripten"
        elif arch == "wasm64":
            return "wasm64-unknown-emscripten"

    return "unknown"
