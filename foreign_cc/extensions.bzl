"""Entry point for extensions used by bzlmod."""

load("@bazel_features//:features.bzl", "bazel_features")
load("//foreign_cc:repositories.bzl", "rules_foreign_cc_dependencies")
load("//toolchains:prebuilt_toolchains.bzl", "prebuilt_toolchains")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//foreign_cc:vcpkg_overrides.bzl", "DEFAULT_PACKAGE_OVERRIDES")

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

def _overlay_dir_for_label(ctx, label):
    """Resolve an overlay label to its package directory on disk.

    `ctx.path(label)` returns `<source_tree>/<package>/<name>` even when no
    on-disk file with that name exists (typical for `filegroup(name=...)`).
    The package dir is the parent of that path, which is where the user's
    overlay-port subdirectories actually live.
    """
    return ctx.path(label).dirname

def _watch_tree(ctx, path):
    """Recursively `ctx.watch` every file under `path` so changes inside an
    overlay invalidate the calling repo or module extension. `path` must be
    a `path` object (from `ctx.path(...)`). Non-existent paths are a no-op.
    """
    if not path.exists:
        return
    if not path.is_dir:
        ctx.watch(path)
        return
    stack = [path]
    for _ in range(1 << 30):  # bounded loop (Starlark has no while)
        if not stack:
            break
        cur = stack.pop()
        for entry in cur.readdir():
            if entry.is_dir:
                stack.append(entry)
            else:
                ctx.watch(entry)

# Capture script invoked by vcpkg's x-script asset source. vcpkg passes
# {sha512} {url} {dst} positional args. We append `<sha512>\t<integrity>\t<url>`
# (integrity = SRI-style base64-encoded sha512) to $VCPKG_BAZEL_CAPTURE_LOG
# and exit 1 so vcpkg skips the asset. With --keep-going, vcpkg enumerates
# every other asset despite each script call failing.
_ASSET_CAPTURE_SCRIPT = """#!/bin/bash
set -u
sha_hex="$1"
url="$2"
b64="$(printf '%s' "$sha_hex" | xxd -r -p | base64)"
printf '%s\t%s\t%s\n' "$sha_hex" "sha512-$b64" "$url" >> "$VCPKG_BAZEL_CAPTURE_LOG"
exit 1
"""

def _vcpkg_capture_repo_impl(repo_ctx):
    vcpkg_root_path = repo_ctx.path(repo_ctx.attr.vcpkg_root_marker).dirname
    vcpkg_exe_basename = "vcpkg.exe" if repo_ctx.os.name.lower().startswith("windows") else "vcpkg"
    vcpkg_exe = vcpkg_root_path.get_child(vcpkg_exe_basename)
    if not vcpkg_exe.exists:
        host_vcpkg = repo_ctx.which(vcpkg_exe_basename)
        if host_vcpkg == None:
            fail("vcpkg: CLI not found in vcpkg root ({}) and not on PATH.".format(vcpkg_exe))
        vcpkg_exe = host_vcpkg

    capture_script = repo_ctx.path("_capture.sh")
    repo_ctx.file(capture_script, _ASSET_CAPTURE_SCRIPT, executable = True)

    manifest_path = repo_ctx.path(repo_ctx.attr.manifest)
    # Refetch whenever the manifest changes — its content drives the set of
    # assets, not just its label identity.
    repo_ctx.watch(manifest_path)
    manifest_dir = manifest_path.dirname

    # Watch the configuration file (vcpkg auto-loads it from the manifest
    # dir, so we just need to make sure it's tracked for refetch).
    if repo_ctx.attr.vcpkg_configuration:
        config_path = repo_ctx.path(repo_ctx.attr.vcpkg_configuration)
        repo_ctx.watch(config_path)
        if config_path.dirname != manifest_dir:
            fail(
                "vcpkg: vcpkg_configuration ({}) must live in the same " +
                "directory as manifest ({}) so vcpkg can auto-load it.".format(
                    config_path,
                    manifest_path,
                ),
            )

    overlay_ports_paths = [_overlay_dir_for_label(repo_ctx, lbl) for lbl in repo_ctx.attr.overlay_ports]
    overlay_triplets_paths = [_overlay_dir_for_label(repo_ctx, lbl) for lbl in repo_ctx.attr.overlay_triplets]
    for p in overlay_ports_paths + overlay_triplets_paths:
        _watch_tree(repo_ctx, p)

    triplet = repo_ctx.attr.triplet
    log_file = repo_ctx.path("_capture.log")
    scratch = repo_ctx.path("_scratch")

    cmd = [
        str(vcpkg_exe),
        "install",
        "--only-downloads",
        "--keep-going",
        "--x-manifest-root={}".format(manifest_dir),
        "--triplet={}".format(triplet),
        "--x-install-root={}/installed".format(scratch),
        "--x-buildtrees-root={}/buildtrees".format(scratch),
        "--x-packages-root={}/packages".format(scratch),
        "--downloads-root={}/downloads".format(scratch),
        "--x-asset-sources=x-block-origin;x-script,{} {{sha512}} {{url}} {{dst}}".format(capture_script),
    ]
    for p in overlay_ports_paths:
        cmd.append("--overlay-ports={}".format(p))
    for p in overlay_triplets_paths:
        cmd.append("--overlay-triplets={}".format(p))

    home_dir = repo_ctx.path("_scratch/home")
    repo_ctx.execute(["mkdir", "-p", str(home_dir)])
    result = repo_ctx.execute(
        cmd,
        environment = {
            "VCPKG_ROOT": str(vcpkg_root_path),
            "VCPKG_BAZEL_CAPTURE_LOG": str(log_file),
            "HOME": str(home_dir),
        },
    )
    # An empty/missing log means vcpkg failed before any port's asset was
    # tried (e.g. cross-compile triplet unreachable from this host). That's
    # not necessarily an error — the user may never build for this triplet —
    # so produce an empty filegroup and let the install action fail later
    # with a clearer error if the missing assets are actually needed.
    seen = {}
    downloads = []  # list of sha512_hex, also the relative filename under downloads/
    if not log_file.exists:
        repo_ctx.file("BUILD.bazel", "filegroup(name = \"all\", srcs = [], visibility = [\"//visibility:public\"])\n")
        return

    for raw in repo_ctx.read(log_file).splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        sha512, integrity, url = parts[0], parts[1], parts[2]
        if sha512 in seen:
            continue
        seen[sha512] = True
        # Filename = sha512 hex. vcpkg_install reads file.basename to recover
        # the sha at action time.
        repo_ctx.download(
            url = url,
            output = "downloads/{}".format(sha512),
            integrity = integrity,
        )
        downloads.append(sha512)

    repo_ctx.file(
        "BUILD.bazel",
        "\n".join([
            "filegroup(",
            "    name = \"all\",",
            "    srcs = [",
        ] + [
            "        \"downloads/{}\",".format(sha) for sha in downloads
        ] + [
            "    ],",
            "    visibility = [\"//visibility:public\"],",
            ")",
            "",
        ]),
    )

_vcpkg_capture_repo = repository_rule(
    implementation = _vcpkg_capture_repo_impl,
    attrs = {
        "manifest": attr.label(mandatory = True, allow_single_file = True),
        "vcpkg_configuration": attr.label(allow_single_file = True),
        "overlay_ports": attr.label_list(allow_files = True),
        "overlay_triplets": attr.label_list(allow_files = True),
        "triplet": attr.string(mandatory = True),
        "vcpkg_root_marker": attr.label(mandatory = True, allow_single_file = True),
    },
)

def _render_override_kwarg(override_doc):
    # Render an override doc ({"entries": [...]}) as the lines for an
    # `override_json = r"""..."""` kwarg in a vcpkg_export(...) call.
    # The string is *raw* so the JSON's own `\"` escapes survive into the
    # generated BUILD literal (otherwise Starlark would unescape them and
    # the json.decode in the rule impl would choke on stray quotes).
    # Returns None when there are no entries (so the caller omits the kwarg).
    if not override_doc.get("entries"):
        return None
    pretty = json.encode_indent(override_doc, indent = "  ")
    return ["    override_json = r\"\"\""] + pretty.splitlines() + ["\"\"\","]

def _list_triplets(repo_ctx, vcpkg_root_path):
    """Enumerate triplet names from <vcpkg_root>/triplets and .../community."""
    triplets = []
    for sub in ("triplets", "triplets/community"):
        d = vcpkg_root_path.get_child(sub)
        if not d.exists:
            continue
        for child in d.readdir():
            name = child.basename
            if name.endswith(".cmake"):
                triplets.append(name[:-len(".cmake")])
    return sorted(triplets)

def _strip_pkg_qualifiers(name):
    # vcpkg names can carry `[feature]` (feature) and `:host` (build for
    # host triplet) qualifiers. For Bazel target purposes we collapse to
    # the bare package name.
    return name.split("[", 1)[0].split(":", 1)[0].strip()

def _parse_depend_info_list(stdout):
    """Parse `vcpkg depend-info --format=list` output into {pkg: [direct_deps]}.

    The format is one line per package: `<pkg>[feature info][:host]: <comma-separated deps>`
    The head/tail separator is `": "` (colon-space) so the optional `:host`
    suffix on the head doesn't confuse the split.
    """
    result = {}
    for raw in stdout.splitlines():
        line = raw.strip()
        if not line or ": " not in line:
            # vcpkg also emits empty-deps lines as `<pkg>: ` (with trailing
            # space stripped by the raw read). Accept those too.
            if line.endswith(":"):
                pkg = _strip_pkg_qualifiers(line[:-1])
                if pkg:
                    result.setdefault(pkg, [])
            continue
        head, _, tail = line.partition(": ")
        pkg = _strip_pkg_qualifiers(head)
        if not pkg:
            continue
        deps = []
        for d in tail.split(","):
            d = _strip_pkg_qualifiers(d)
            if d and d != pkg:
                deps.append(d)
        result[pkg] = deps
    return result

def _vcpkg_repo_impl(repo_ctx):
    vcpkg_install_target_name = "install_tree"

    manifest_path = repo_ctx.path(repo_ctx.attr.manifest)
    repo_ctx.watch(manifest_path)
    manifest = json.decode(repo_ctx.read(manifest_path))
    packages = []
    # TODO(TheGrizzlyDev): handle the manifest's `builtin-baseline`. Today
    # it's ignored.
    for dep in manifest.get("dependencies", []):
        if type(dep) == "string":
            packages.append(dep)
        else:
            packages.append(dep["name"])

    overrides_by_pkg = json.decode(repo_ctx.attr.overrides_json)

    triplet_mappings = json.decode(repo_ctx.attr.triplet_mappings_json)

    # Resolve the vcpkg root checkout path so we can enumerate triplets and
    # invoke vcpkg from it. `vcpkg_root_marker` is a label into the
    # @<vcpkg_root>//:.vcpkg-root file; its parent directory is the root.
    vcpkg_root_path = repo_ctx.path(repo_ctx.attr.vcpkg_root_marker).dirname
    vcpkg_exe_basename = "vcpkg.exe" if repo_ctx.os.name.lower().startswith("windows") else "vcpkg"
    vcpkg_exe = vcpkg_root_path.get_child(vcpkg_exe_basename)
    if not vcpkg_exe.exists:
        host_vcpkg = repo_ctx.which(vcpkg_exe_basename)
        if host_vcpkg == None:
            fail("vcpkg: CLI not found in vcpkg root ({}) and not on PATH. Bootstrap the root (run `bootstrap-vcpkg.sh`) or install vcpkg on the host.".format(vcpkg_exe))
        vcpkg_exe = host_vcpkg

    # Per-repo scratch root for vcpkg's mutable directories. Treat the vcpkg
    # root checkout as immutable so concurrent actions don't fight over
    # `buildtrees/vcpkg-running.lock`. The repo name segment scopes the
    # scratch path so multiple `vcpkg.source(...)` repos don't collide.
    scratch_root = repo_ctx.path(".vcpkg-scratch/{}".format(repo_ctx.name))

    # Run depend-info only for triplets the user actually maps to (via
    # vcpkg.triplet_mapping, including built-in defaults). Iterating every
    # community triplet would shell out 100+ times for triplets we never
    # build for and many of which fail (cross-toolchains, host mismatches).
    target_triplets = sorted({tm["triplet"]: True for tm in triplet_mappings}.keys())

    # Resolve overlay dirs and watch their contents so changes invalidate
    # the repo. Config file lives next to the manifest; vcpkg auto-loads it.
    if repo_ctx.attr.vcpkg_configuration:
        repo_ctx.watch(repo_ctx.path(repo_ctx.attr.vcpkg_configuration))
    overlay_ports_paths = [_overlay_dir_for_label(repo_ctx, lbl) for lbl in repo_ctx.attr.overlay_ports]
    overlay_triplets_paths = [_overlay_dir_for_label(repo_ctx, lbl) for lbl in repo_ctx.attr.overlay_triplets]
    for p in overlay_ports_paths + overlay_triplets_paths:
        _watch_tree(repo_ctx, p)

    home_dir = repo_ctx.path("{}/home".format(scratch_root))
    repo_ctx.execute(["mkdir", "-p", str(home_dir)])
    deps_by_triplet_by_pkg = {}  # pkg -> {triplet: [direct deps]}
    manifest_dir = manifest_path.dirname
    for triplet in target_triplets:
        triplet_scratch = "{}/depend-info/{}".format(scratch_root, triplet)
        cmd = [
            str(vcpkg_exe),
            "depend-info",
            "--format=list",
            "--x-manifest-root={}".format(manifest_dir),
            "--triplet={}".format(triplet),
            "--x-install-root={}/installed".format(triplet_scratch),
            "--x-buildtrees-root={}/buildtrees".format(triplet_scratch),
            "--x-packages-root={}/packages".format(triplet_scratch),
            "--downloads-root={}/downloads".format(triplet_scratch),
        ]
        for p in overlay_ports_paths:
            cmd.append("--overlay-ports={}".format(p))
        for p in overlay_triplets_paths:
            cmd.append("--overlay-triplets={}".format(p))
        result = repo_ctx.execute(cmd, environment = {
            "VCPKG_ROOT": str(vcpkg_root_path),
            "HOME": str(home_dir),
        })
        if result.return_code != 0:
            fail(
                "vcpkg depend-info failed for triplet '{}'.\nstderr:\n{}\nstdout:\n{}".format(
                    triplet,
                    result.stderr,
                    result.stdout,
                ),
            )
        # vcpkg writes the dep list to stderr (stdout is empty), so parse
        # both to be robust.
        graph = _parse_depend_info_list(result.stdout + "\n" + result.stderr)
        for pkg, deps in graph.items():
            deps_by_triplet_by_pkg.setdefault(pkg, {})[triplet] = deps

    # Emit one config_setting per unique constraint set. Two mappings that
    # share a constraint set but resolve to different triplets are an
    # ambiguity the user must resolve — fail eagerly with the list.
    config_setting_for = {}  # constraint-set tuple -> config_setting name
    triplet_for_key = {}     # constraint-set tuple -> triplet name (for dup check)
    config_setting_for_triplet = {}  # triplet name -> ":<config_setting>" label
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
        config_setting_for_triplet[tm["triplet"]] = label

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
        "load(\"@rules_foreign_cc//foreign_cc:vcpkg.bzl\", \"vcpkg_install\", \"vcpkg_export\")",
        "load(\"@rules_foreign_cc//foreign_cc/private/framework:platform.bzl\", \"vcpkg_triplet_info_from_mappings\")",
        "",
    ] + config_setting_blocks + triplet_info_blocks

    downloads_by_triplet = json.decode(repo_ctx.attr.downloads_by_triplet_json)
    install_block = [
        "vcpkg_install(",
        "    name = \"{}\",".format(vcpkg_install_target_name),
        "    root = \"@{}//:srcs\",".format(repo_ctx.attr.vcpkg_root),
        "    root_file = \"@{}//:.vcpkg-root\",".format(repo_ctx.attr.vcpkg_root),
        "    manifest = \"{}\",".format(repo_ctx.attr.manifest),
        "    triplet = \":{}\",".format(triplet_info_target),
    ]
    if repo_ctx.attr.vcpkg_configuration:
        install_block.append("    vcpkg_configuration = \"{}\",".format(repo_ctx.attr.vcpkg_configuration))
    if repo_ctx.attr.overlay_ports:
        install_block.append("    overlay_ports = [")
        for lbl in repo_ctx.attr.overlay_ports:
            install_block.append("        \"{}\",".format(lbl))
        install_block.append("    ],")
    if repo_ctx.attr.overlay_triplets:
        install_block.append("    overlay_triplets = [")
        for lbl in repo_ctx.attr.overlay_triplets:
            install_block.append("        \"{}\",".format(lbl))
        install_block.append("    ],")
    if downloads_by_triplet:
        install_block.append("    downloads_by_triplet = {")
        for t in sorted(downloads_by_triplet.keys()):
            install_block.append("        \"{}\": \"{}\",".format(t, downloads_by_triplet[t]))
        install_block.append("    },")
    install_block += [")", ""]
    lines += install_block
    # TODO(TheGrizzlyDev): allow the override schema's `deps` field to
    # override the auto-derived vcpkg_deps_by_triplet entries for a package
    # (manual escape hatch when the depend-info-derived graph is wrong).
    # TODO(TheGrizzlyDev): surface tools/* binaries when the override schema's
    # `out_binaries` field is populated. Today tools/* is unconditionally
    # filtered out by the export script.
    # Collect every package that appears anywhere in the resolved dep graph
    # (across any triplet), not just the top-level manifest deps. Transitive
    # vcpkg_export targets need to exist for the deps to point at them.
    all_packages = {p: True for p in packages}
    for pkg, by_triplet in deps_by_triplet_by_pkg.items():
        all_packages[pkg] = True
        for triplet_deps in by_triplet.values():
            for d in triplet_deps:
                all_packages[d] = True

    for pkg in sorted(all_packages.keys()):
        block = [
            "vcpkg_export(",
            "    name = \"{}\",".format(pkg),
            "    install_tree = \":{}\",".format(vcpkg_install_target_name),
            "    package = \"{}\",".format(pkg),
            "    triplet = \":{}\",".format(triplet_info_target),
        ]

        rendered = _render_override_kwarg(overrides_by_pkg.get(pkg) or {})
        if rendered:
            block += rendered

        by_triplet = deps_by_triplet_by_pkg.get(pkg) or {}
        non_empty = {t: d for t, d in by_triplet.items() if d}
        if non_empty:
            # Emit `deps = select({"<config_setting>": [...], ...})`. The
            # active triplet's config_setting picks the right list at
            # analysis time.
            block.append("    deps = select({")
            for triplet in sorted(non_empty.keys()):
                cs = config_setting_for_triplet.get(triplet)
                if cs == None:
                    continue
                deps_str = ", ".join(["\":{}\"".format(d) for d in sorted(non_empty[triplet])])
                block.append("        \"{}\": [{}],".format(cs, deps_str))
            block.append("    }),")

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
        "manifest": attr.label(allow_single_file = True),
        "vcpkg_configuration": attr.label(allow_single_file = True),
        "overlay_ports": attr.label_list(allow_files = True),
        "overlay_triplets": attr.label_list(allow_files = True),
        "overrides_json": attr.string(
            default = "[]",
            doc = "JSON-encoded list of per-package override dicts. See vcpkg.package_override.",
        ),
        "triplet_mappings_json": attr.string(
            default = "[]",
            doc = "JSON-encoded list of {constraints, triplet} dicts. See vcpkg.triplet_mapping.",
        ),
        "downloads_by_triplet_json": attr.string(
            default = "{}",
            doc = "JSON-encoded {triplet: capture_repo_label} for vcpkg's asset cache (one filegroup label per triplet pointing at the @vcpkg_downloads_*//all target).",
        ),
        "vcpkg_root": attr.string(mandatory = True),
        "vcpkg_root_marker": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Label of the @<vcpkg_root>//:.vcpkg-root anchor file. Used " +
                  "to resolve the vcpkg root path at fetch time.",
        ),
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
    "manifest": attr.label(default = "@__main__//:vcpkg.json", allow_single_file = True),
    "vcpkg_configuration": attr.label(
        doc = (
            "Optional vcpkg-configuration.json. Must live in the same Bazel " +
            "package as `manifest` so vcpkg can auto-load it via " +
            "--x-manifest-root."
        ),
        allow_single_file = True,
    ),
    "overlay_ports": attr.label_list(
        doc = (
            "Overlay-port directories passed to vcpkg via --overlay-ports. " +
            "Each label should resolve to a directory (e.g. a " +
            "`bazel_skylib` `directory` target or a filegroup with " +
            "`allow_empty = False`)."
        ),
        allow_files = True,
    ),
    "overlay_triplets": attr.label_list(
        doc = (
            "Overlay-triplet directories passed to vcpkg via " +
            "--overlay-triplets. Same shape constraints as `overlay_ports`."
        ),
        allow_files = True,
    ),
    "root": attr.string(default = DEFAULT_VCPKG_ROOT_WORKSPACE_NAME),
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

def _user_entry_covers_default(user_entry, default_entry):
    # Drop a default whenever a user entry matches at least the same
    # configurations: universal user (no triplet / no compilation_mode)
    # covers any default; a scoped user covers only same-scoped defaults.
    for field in ("triplet", "compilation_mode"):
        user_v = user_entry.get(field)
        if user_v != None and user_v != default_entry.get(field):
            return False
    return True

def _merged_overrides_for_package(user_entries, default_entries):
    kept_defaults = [
        d
        for d in default_entries
        if not any([_user_entry_covers_default(u, d) for u in user_entries])
    ]
    return user_entries + kept_defaults

vcpkg_package_override = tag_class(attrs = {
    "source": attr.string(
        doc = "The name of the vcpkg.source repo these overrides apply to.",
        mandatory = True,
    ),
    "package": attr.string(
        doc = (
            "vcpkg package name to override. String values inside the " +
            "`out_*` list attrs may reference `$$VCPKG_TRIPLET$$` and " +
            "`$$VCPKG_PACKAGE$$` (plus their `_UPPER` / `_LOWER` casing " +
            "variants) which are substituted at analysis time."
        ),
        mandatory = True,
    ),
    "triplet": attr.string(
        doc = "If non-empty, restricts this override to this triplet.",
        default = "",
    ),
    "compilation_mode": attr.string(
        doc = (
            "If non-empty, restricts this override to this Bazel compilation " +
            "mode (`dbg`, `opt`, `fastbuild`). When unset, the override " +
            "applies to all modes — and is shadowed by any mode-specific " +
            "override for the same (source, package, triplet)."
        ),
        values = ["", "dbg", "opt", "fastbuild"],
        default = "",
    ),
    "out_static_libs": attr.string_list(default = []),
    "out_shared_libs": attr.string_list(default = []),
    "out_interface_libs": attr.string_list(default = []),
    "out_binaries": attr.string_list(default = []),
    "out_headers_only": attr.bool(default = False),
    "defines": attr.string_list(default = []),
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

    # TODO(TheGrizzlyDev): pin the root per vcpkg.source. Today repeated tags
    # with the same `name` silently produce an http_archive collision, and
    # vcpkg.source has no way to scope a root to itself. Either fail loud on
    # duplicates or thread an explicit root selection through each source.
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
        
    # Aggregate overrides per (source.name, package) into a list of entries.
    # Each `package_override` tag becomes one entry; the entry's optional
    # `triplet` and `compilation_mode` fields scope it. The vcpkg_export rule
    # picks the most-specific matching entry at analysis time.
    _OV_LIST_FIELDS = ("out_static_libs", "out_shared_libs", "out_interface_libs", "out_binaries", "defines")
    overrides_by_source = {}
    for mod in module_ctx.modules:
        for ov in mod.tags.package_override:
            by_pkg = overrides_by_source.setdefault(ov.source, {})
            entries = by_pkg.setdefault(ov.package, [])

            entry = {}
            if ov.triplet:
                entry["triplet"] = ov.triplet
            if ov.compilation_mode:
                entry["compilation_mode"] = ov.compilation_mode
            for field in _OV_LIST_FIELDS:
                values = getattr(ov, field)
                if values:
                    entry[field] = list(values)
            if ov.out_headers_only:
                entry["out_headers_only"] = True

            # Skip tags that carry only scoping metadata and no payload.
            payload_present = any([k for k in entry.keys() if k not in ("triplet", "compilation_mode")])
            if payload_present:
                entries.append(entry)

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
    target_triplets = sorted({tm["triplet"]: True for tm in triplet_mappings}.keys())

    # Bucket built-in default overrides by package so we can merge per
    # source. Each entry copies its dict and strips the `package` key to
    # match the in-memory shape of user entries.
    defaults_by_package = {}
    for d in DEFAULT_PACKAGE_OVERRIDES:
        entry = {k: v for k, v in d.items() if k != "package"}
        defaults_by_package.setdefault(d["package"], []).append(entry)

    for mod in module_ctx.modules:
        for source in mod.tags.source:
            by_pkg = overrides_by_source.get(source.name, {})
            applicable = {}
            packages = sorted({p: True for p in (list(by_pkg.keys()) + list(defaults_by_package.keys()))}.keys())
            for pkg in packages:
                user_entries = by_pkg.get(pkg, [])
                default_entries = defaults_by_package.get(pkg, [])
                merged = _merged_overrides_for_package(user_entries, default_entries)
                if merged:
                    applicable[pkg] = {"entries": merged}

            # Declare one capture repo per (source, triplet). Each runs vcpkg
            # to enumerate the assets for its triplet and downloads them via
            # repo_ctx.download into downloads/<sha512>. The repo exposes a
            # single `:all` filegroup that vcpkg_install consumes.
            downloads_by_triplet = {}
            for triplet in target_triplets:
                capture_repo = "vcpkg_downloads_{}_{}".format(source.name, triplet.replace("-", "_"))
                _vcpkg_capture_repo(
                    name = capture_repo,
                    manifest = source.manifest,
                    vcpkg_configuration = source.vcpkg_configuration,
                    overlay_ports = source.overlay_ports,
                    overlay_triplets = source.overlay_triplets,
                    triplet = triplet,
                    vcpkg_root_marker = "@{}//:.vcpkg-root".format(vcpkg_repo_name(source.root)),
                )
                downloads_by_triplet[triplet] = "@{}//:all".format(capture_repo)

            vcpkg_repo(
                name = source.name,
                manifest = source.manifest,
                vcpkg_configuration = source.vcpkg_configuration,
                overlay_ports = source.overlay_ports,
                overlay_triplets = source.overlay_triplets,
                vcpkg_root = vcpkg_repo_name(source.root),
                vcpkg_root_marker = "@{}//:.vcpkg-root".format(vcpkg_repo_name(source.root)),
                overrides_json = json.encode(applicable),
                triplet_mappings_json = json.encode(triplet_mappings),
                downloads_by_triplet_json = json.encode(downloads_by_triplet),
            )
    return None

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