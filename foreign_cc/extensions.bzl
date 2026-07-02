"""Entry point for extensions used by bzlmod."""

load("@bazel_features//:features.bzl", "bazel_features")
load("//foreign_cc:repositories.bzl", "rules_foreign_cc_dependencies")
load("//toolchains:prebuilt_toolchains.bzl", "prebuilt_toolchains")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load("//foreign_cc:vcpkg_overrides.bzl", "DEFAULT_PACKAGE_OVERRIDES")
load("//toolchains/private:cmake_versions.bzl", "CMAKE_BIN_SRCS")

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

def _host_path_env(ctx):
    """Best-effort fetch of the host PATH so we can prepend our own bin
    dir without throwing away the user's environment. Falls back to a
    minimal POSIX default if PATH isn't exported.
    """
    result = ctx.execute(["sh", "-c", "echo \"$PATH\""])
    if result.return_code == 0:
        path = result.stdout.strip()
        if path:
            return path
    return "/usr/local/bin:/usr/bin:/bin"

def _overlay_dir_for_label(ctx, label):
    """Resolve an overlay label to its package directory on disk.

    `ctx.path(label)` returns `<source_tree>/<package>/<name>` even when no
    on-disk file with that name exists (typical for `filegroup(name=...)`).
    The package dir is the parent of that path, which is where the user's
    overlay-port subdirectories actually live.
    """
    return ctx.path(label).dirname

def _manifest_baseline(ctx, manifest_label):
    """Return the manifest's `builtin-baseline` field, or None if absent."""
    return json.decode(ctx.read(ctx.path(manifest_label))).get("builtin-baseline")

def _sanitise_ref(ref):
    """Make `ref` safe to embed in a Bazel workspace name."""
    out = ""
    for ch in ref.elems():
        out += ch if (ch.isalnum() or ch == "_") else "_"
    return out

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

VCPKG_ROOT_BUILD_FILE = """
exports_files([".vcpkg-root"])

filegroup(
    name = "srcs",
    srcs = glob(["**/*"]),
    visibility = ["//visibility:public"],
)
""".strip()

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
    vcpkg_exe = repo_ctx.path(repo_ctx.attr.vcpkg_cli)
    cmake_bin_dir = repo_ctx.path(repo_ctx.attr.cmake_bin).dirname

    capture_script = repo_ctx.path("_capture.sh")
    repo_ctx.file(capture_script, _ASSET_CAPTURE_SCRIPT, executable = True)

    manifest_path = repo_ctx.path(repo_ctx.attr.manifest)
    # Refetch whenever the manifest changes — its content drives the set of
    # assets, not just its label identity.
    repo_ctx.watch(manifest_path)
    manifest_dir = manifest_path.dirname
    declared_features = sorted(json.decode(repo_ctx.read(manifest_path)).get("features", {}).keys())

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
    # If vcpkg_configuration is set the config is the source of truth for
    # overlays; label-declared overlays only exist for Bazel visibility.
    if not repo_ctx.attr.vcpkg_configuration:
        for p in overlay_ports_paths:
            cmd.append("--overlay-ports={}".format(p))
        for p in overlay_triplets_paths:
            cmd.append("--overlay-triplets={}".format(p))
    for feat in declared_features:
        cmd.append("--x-feature={}".format(feat))

    home_dir = repo_ctx.path("_scratch/home")
    repo_ctx.execute(["mkdir", "-p", str(home_dir)])
    result = repo_ctx.execute(
        cmd,
        environment = {
            "VCPKG_ROOT": str(vcpkg_root_path),
            "VCPKG_BAZEL_CAPTURE_LOG": str(log_file),
            "HOME": str(home_dir),
            # Force vcpkg to find cmake on PATH rather than downloading its
            # own copy; the path we prepend points at rules_foreign_cc's
            # prebuilt cmake archive.
            "VCPKG_FORCE_SYSTEM_BINARIES": "1",
            "PATH": "{}:{}".format(cmake_bin_dir, _host_path_env(repo_ctx)),
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
        "vcpkg_cli": attr.label(mandatory = True, allow_single_file = True),
        "cmake_bin": attr.label(mandatory = True, allow_single_file = True),
    },
)

def _vcpkg_git_root_repo_impl(repo_ctx):
    # Unlike Bazel's `git_repository`, keep `.git/` intact so
    # `_vcpkg_repo_impl` can run `git show <baseline>:versions/baseline.json`
    # against it at depend-info time.
    remote = repo_ctx.attr.remote
    ref = repo_ctx.attr.ref
    ref_kind = repo_ctx.attr.ref_kind
    shallow_since = repo_ctx.attr.shallow_since
    init_submodules = repo_ctx.attr.init_submodules
    recursive = repo_ctx.attr.recursive_init_submodules

    target = repo_ctx.path(".")
    def _git(args, check = True):
        result = repo_ctx.execute(["git"] + args, working_directory = str(target))
        if check and result.return_code != 0:
            fail("vcpkg root git clone: `git {}` failed ({}):\nstderr:\n{}\nstdout:\n{}".format(
                " ".join(args), result.return_code, result.stderr, result.stdout,
            ))
        return result

    _git(["init", "--quiet"])
    _git(["remote", "add", "origin", remote])
    fetch_args = ["fetch", "--quiet"]
    if shallow_since:
        fetch_args += ["--shallow-since={}".format(shallow_since)]
    elif ref_kind == "commit":
        fetch_args += ["--depth=1"]
    fetch_args += ["origin", ref]
    _git(fetch_args)

    if ref_kind == "commit":
        _git(["checkout", "--quiet", ref])
    else:
        _git(["checkout", "--quiet", "FETCH_HEAD"])

    if init_submodules:
        sub_args = ["submodule", "update", "--init"]
        if recursive:
            sub_args += ["--recursive"]
        _git(sub_args)

    repo_ctx.file("BUILD.bazel", VCPKG_ROOT_BUILD_FILE)
    if not repo_ctx.path(".vcpkg-root").exists:
        repo_ctx.file(".vcpkg-root", "")

_vcpkg_git_root_repo = repository_rule(
    implementation = _vcpkg_git_root_repo_impl,
    attrs = {
        "remote": attr.string(mandatory = True),
        "ref": attr.string(mandatory = True),
        "ref_kind": attr.string(
            mandatory = True,
            values = ["commit", "tag", "branch"],
        ),
        "shallow_since": attr.string(),
        "init_submodules": attr.bool(default = False),
        "recursive_init_submodules": attr.bool(default = True),
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

    # NOTE: `builtin-baseline` is handled upstream in `_vcpkg_mod`: when
    # the source's manifest carries one, we synthesise a git_repository
    # pinned at that commit and route this source at it. So by the time
    # we get here, the on-disk root's working tree already matches the
    # baseline — no reachability probe needed.

    for dep in manifest.get("dependencies", []):
        if type(dep) == "string":
            packages.append(dep)
        else:
            packages.append(dep["name"])

    # Top-level features declared in the manifest. Every declared feature
    # gets enabled for depend-info and the asset-capture pass so the
    # generated dep graph and asset cache cover all user-selectable
    # feature combinations. At install time the user picks a subset via
    # the `:features` string_list_flag we emit into the generated BUILD.
    declared_features = sorted(manifest.get("features", {}).keys())

    # Write a scrubbed manifest for the install action: strip
    # `builtin-baseline`/`overrides`, both of which make vcpkg run
    # `git show <sha>:versions/…` against the root's `.git/`. Bazel
    # materialises action inputs as symlinks and git rejects a symlinked
    # `.git/HEAD`, so the install-time git lookup would fail. Depend-info
    # (above) has already consumed both fields, so the resolved graph is
    # unchanged; empirically install output matches the baseline-honoured
    # run when the root's working tree is at the baseline commit.
    scrubbed_manifest = {k: v for k, v in manifest.items() if k not in ("builtin-baseline", "overrides")}
    repo_ctx.file("install/vcpkg.json", json.encode_indent(scrubbed_manifest, indent = "  "))

    have_scrubbed_config = False
    if repo_ctx.attr.vcpkg_configuration:
        config_path = repo_ctx.path(repo_ctx.attr.vcpkg_configuration)
        config = json.decode(repo_ctx.read(config_path))
        config_dir = config_path.dirname

        def _reject_artifact(reg, where):
            if type(reg) != "dict":
                return
            if reg.get("kind") == "artifact":
                fail(
                    ("vcpkg.source '{src}': vcpkg-configuration.json declares " +
                     "a `kind: \"artifact\"` registry at {where} " +
                     "(name={name}, location={loc}). Artifact registries " +
                     "(vcpkg-ce) are not supported by rules_foreign_cc.").format(
                        src = repo_ctx.name,
                        where = where,
                        name = reg.get("name"),
                        loc = reg.get("location"),
                    ),
                )

        _reject_artifact(config.get("default-registry"), "default-registry")
        for idx, reg in enumerate(config.get("registries", []) or []):
            _reject_artifact(reg, "registries[{}]".format(idx))

        def _strip_baseline(reg):
            return {k: v for k, v in reg.items() if k != "baseline"}
        if "default-registry" in config and type(config["default-registry"]) == "dict":
            config["default-registry"] = _strip_baseline(config["default-registry"])
        if "registries" in config:
            config["registries"] = [_strip_baseline(r) for r in config["registries"]]

        # `overlay-ports` / `overlay-triplets` entries in the config are
        # relative to the config file's directory. Copy the referenced
        # trees into `install/<same-relative-path>` so vcpkg-in-sandbox
        # resolves them relative to the scrubbed config identically.
        for field in ("overlay-ports", "overlay-triplets"):
            for entry in config.get(field, []) or []:
                if type(entry) != "string":
                    fail("vcpkg.source '{}': non-string entry in {} of vcpkg-configuration.json: {}".format(
                        repo_ctx.name, field, entry,
                    ))
                if entry.startswith("/"):
                    fail(
                        ("vcpkg.source '{src}': vcpkg-configuration.json's " +
                         "{field} contains an absolute path {entry}. " +
                         "Absolute paths aren't hermetic across the Bazel " +
                         "sandbox; use a relative path (resolved against " +
                         "the config file's directory).").format(
                            src = repo_ctx.name, field = field, entry = entry,
                        ),
                    )
                source_tree = config_dir.get_child(entry)
                if not source_tree.exists:
                    fail(
                        ("vcpkg.source '{src}': vcpkg-configuration.json's " +
                         "{field} references '{entry}', which resolves to " +
                         "{path} but no such file/directory exists.").format(
                            src = repo_ctx.name, field = field, entry = entry,
                            path = str(source_tree),
                        ),
                    )
                _watch_tree(repo_ctx, source_tree)
                # `install/vcpkg-configuration.json` lives at
                # `install/`, so vcpkg (in the sandbox) resolves `entry`
                # against `install/`. Materialise the tree there.
                dest = repo_ctx.path("install/{}".format(entry))
                repo_ctx.execute(["mkdir", "-p", str(dest.dirname)])
                repo_ctx.execute(["cp", "-R", str(source_tree), str(dest)])

        repo_ctx.file("install/vcpkg-configuration.json", json.encode_indent(config, indent = "  "))
        have_scrubbed_config = True

    overrides_by_pkg = json.decode(repo_ctx.attr.overrides_json)

    triplet_mappings = json.decode(repo_ctx.attr.triplet_mappings_json)

    # Resolve the vcpkg root checkout path so we can enumerate triplets and
    # invoke vcpkg from it. `vcpkg_root_marker` is a label into the
    # @<vcpkg_root>//:.vcpkg-root file; its parent directory is the root.
    vcpkg_root_path = repo_ctx.path(repo_ctx.attr.vcpkg_root_marker).dirname
    vcpkg_exe = repo_ctx.path(repo_ctx.attr.vcpkg_cli)
    cmake_bin_dir = repo_ctx.path(repo_ctx.attr.cmake_bin).dirname

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
        # See capture-repo command builder above: when a config is set,
        # vcpkg auto-loads its overlays; we don't thread label-declared
        # overlays through the CLI in that case.
        if not repo_ctx.attr.vcpkg_configuration:
            for p in overlay_ports_paths:
                cmd.append("--overlay-ports={}".format(p))
            for p in overlay_triplets_paths:
                cmd.append("--overlay-triplets={}".format(p))
        for feat in declared_features:
            cmd.append("--x-feature={}".format(feat))
        result = repo_ctx.execute(cmd, environment = {
            "VCPKG_ROOT": str(vcpkg_root_path),
            "HOME": str(home_dir),
            "VCPKG_FORCE_SYSTEM_BINARIES": "1",
            "PATH": "{}:{}".format(cmake_bin_dir, _host_path_env(repo_ctx)),
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

    # Nested BUILD so vcpkg_install can reference the scrubbed manifest
    # (and optional config) via a label pointing at the `install/` subdir.
    # `config_data` captures any auxiliary files staged next to the config
    # (e.g. overlay-port trees copied for `overlay-ports` entries in the
    # config), so the install action's sandbox mirrors the config's own
    # relative-path layout.
    install_exports = ["vcpkg.json"]
    if have_scrubbed_config:
        install_exports.append("vcpkg-configuration.json")
    install_build_lines = [
        "exports_files({})".format(install_exports),
        "",
        "filegroup(",
        "    name = \"config_data\",",
        "    srcs = glob([\"**/*\"], exclude = [\"BUILD.bazel\", \"vcpkg.json\"], allow_empty = True),",
        "    visibility = [\"//visibility:public\"],",
        ")",
        "",
    ]
    repo_ctx.file("install/BUILD.bazel", "\n".join(install_build_lines))
    lines = [
        "load(\"@rules_foreign_cc//foreign_cc:vcpkg.bzl\", \"vcpkg_install\", \"vcpkg_export\")",
        "load(\"@rules_foreign_cc//foreign_cc/private/framework:platform.bzl\", \"vcpkg_triplet_info_from_mappings\")",
    ]
    if declared_features:
        lines.append("load(\"@bazel_skylib//rules:common_settings.bzl\", \"string_list_flag\")")
    lines.append("")
    lines += config_setting_blocks + triplet_info_blocks

    if declared_features:
        lines += [
            "string_list_flag(",
            "    name = \"features\",",
            "    build_setting_default = [],",
            "    visibility = [\"//visibility:public\"],",
            ")",
            "",
        ]

    downloads_by_triplet = json.decode(repo_ctx.attr.downloads_by_triplet_json)
    install_block = [
        "vcpkg_install(",
        "    name = \"{}\",".format(vcpkg_install_target_name),
        "    root = \"@{}//:srcs\",".format(repo_ctx.attr.vcpkg_root),
        "    root_file = \"@{}//:.vcpkg-root\",".format(repo_ctx.attr.vcpkg_root),
        "    manifest = \"//install:vcpkg.json\",",
        "    vcpkg_cli = \"{}\",".format(repo_ctx.attr.vcpkg_cli),
        "    triplet = \":{}\",".format(triplet_info_target),
    ]
    if declared_features:
        install_block.append("    features_flag = \":features\",")
        install_block.append("    declared_features = {},".format(declared_features))
    if have_scrubbed_config:
        install_block.append("    vcpkg_configuration = \"//install:vcpkg-configuration.json\",")
        install_block.append("    config_data = \"//install:config_data\",")
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
        "vcpkg_cli": attr.label(mandatory = True, allow_single_file = True),
        "cmake_bin": attr.label(mandatory = True, allow_single_file = True),
    }
)

DEFAULT_VCPKG_ROOT_WORKSPACE_NAME = "default_vcpkg_root"

vcpkg_root_http_archive = tag_class(attrs = {
    "name": attr.string(
        default = DEFAULT_VCPKG_ROOT_WORKSPACE_NAME,
        doc = (
            "Logical name for this root. Referenced by " +
            "`vcpkg.source(root = ...)`. Defaults to the built-in default " +
            "root name so a manifest can use it without an explicit `root`."
        ),
    ),
    "urls": attr.string_list(
        mandatory = True,
        doc = "Mirror URLs passed verbatim to http_archive.",
    ),
    "sha256": attr.string(
        doc = "Tarball sha256 passed verbatim to http_archive.",
    ),
    "strip_prefix": attr.string(
        doc = "strip_prefix passed verbatim to http_archive.",
    ),
})

# A source's manifest baseline (when present) picks the fetched ref;
# otherwise one of the `fallback_*` fields is used.
vcpkg_root_git_repository = tag_class(attrs = {
    "name": attr.string(
        default = DEFAULT_VCPKG_ROOT_WORKSPACE_NAME,
        doc = (
            "Logical name for this root. Referenced by " +
            "`vcpkg.source(root = ...)`."
        ),
    ),
    "remote": attr.string(
        mandatory = True,
        doc = "Git remote URL (e.g. https://github.com/microsoft/vcpkg).",
    ),
    "fallback_commit": attr.string(
        doc = (
            "Commit sha used when the consuming source's manifest does not " +
            "declare `builtin-baseline`. One of `fallback_commit`, " +
            "`fallback_tag`, or `fallback_branch` should be set when " +
            "baseline-less manifests will use this root."
        ),
    ),
    "fallback_tag": attr.string(
        doc = "Like `fallback_commit`, but a tag name.",
    ),
    "fallback_branch": attr.string(
        doc = (
            "Like `fallback_commit`, but a branch name. Refetched on every " +
            "run; prefer `fallback_commit` for reproducibility."
        ),
    ),
    "shallow_since": attr.string(
        doc = (
            "Optional `shallow_since` passed through to the synthesised " +
            "git_repository. Trades fetch size for reachability."
        ),
    ),
    "init_submodules": attr.bool(default = False),
    "recursive_init_submodules": attr.bool(default = True),
})

# Asset filenames published by github.com/microsoft/vcpkg-tool releases.
# Keep this list and the default sha256 map below in sync with the chosen
# default version.
_DEFAULT_VCPKG_TOOL_VERSION = "2026-05-27"
_DEFAULT_VCPKG_TOOL_SHA256_PER_ASSET = {
    "vcpkg-macos": "c34e943e3513e96dc7d9b6a96150a3dc059b92542318af9e993e2dd473cb7fef",
    "vcpkg-glibc": "459de9d0d4dbdfbec760d87a2d62e48f94c1f60b5473498b4505689df045c35b",
    "vcpkg-glibc-arm64": "5e5ce3a57c06473f1e8a161d15679860e987d706d5b5259045f6a392fc9acca9",
    "vcpkg.exe": "da75e3312ff6881c89f6171363eedb92933b0f79456cd6ee636316edef860ff7",
    "vcpkg-arm64.exe": "371cf5285cc94932b97c8c0774066c90efdb50dfe606113f1686e6e99f928b08",
}

vcpkg_tool_from_upstream_release = tag_class(attrs = {
    "version": attr.string(
        default = _DEFAULT_VCPKG_TOOL_VERSION,
        doc = "Tag of the github.com/microsoft/vcpkg-tool release to fetch.",
    ),
    "sha256_per_asset": attr.string_dict(
        default = _DEFAULT_VCPKG_TOOL_SHA256_PER_ASSET,
        doc = (
            "SHA-256 per release asset filename (e.g. `vcpkg-macos`, " +
            "`vcpkg-glibc`, `vcpkg.exe`). The extension picks the asset " +
            "matching the host at fetch time."
        ),
    ),
    "strict_file_set": attr.bool(
        default = True,
        doc = (
            "When True (default), every entry in the default asset set " +
            "must have an SHA-256 in `sha256_per_asset`. When False, " +
            "missing entries are tolerated until a fetch on a host that " +
            "needs that specific asset is attempted."
        ),
    ),
})

def _vcpkg_cli_asset_for_host(os_name, arch):
    """Pick the upstream release asset matching this host."""
    os_name = os_name.lower()
    if os_name.startswith("mac"):
        return "vcpkg-macos"
    if os_name.startswith("linux"):
        if "aarch64" in arch or "arm64" in arch:
            return "vcpkg-glibc-arm64"
        return "vcpkg-glibc"
    if os_name.startswith("windows"):
        if "aarch64" in arch or "arm64" in arch:
            return "vcpkg-arm64.exe"
        return "vcpkg.exe"
    fail("vcpkg: no upstream release asset known for host os={} arch={}".format(os_name, arch))

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

def _vcpkg_mod(module_ctx):
    # A tag becomes a template; each source resolves it to a concrete repo.
    # http_archive templates fetch once; git templates fan out per unique ref.
    http_templates = {}
    git_templates = {}

    def _check_template_collision(name, new):
        existing = http_templates.get(name) or git_templates.get(name)
        if existing == None:
            return
        if existing != new:
            fail(
                ("vcpkg: root '{}' is declared more than once with " +
                 "different parameters. First declaration: {}. " +
                 "Conflicting declaration: {}.").format(name, existing, new),
            )

    for mod in module_ctx.modules:
        for root_tag in mod.tags.root_http_archive:
            name = root_tag.name
            params = struct(
                kind = "http_archive",
                urls = tuple(root_tag.urls),
                sha256 = root_tag.sha256,
                strip_prefix = root_tag.strip_prefix,
            )
            _check_template_collision(name, params)
            http_templates[name] = params

        for root_tag in mod.tags.root_git_repository:
            name = root_tag.name
            params = struct(
                kind = "git_repository",
                remote = root_tag.remote,
                fallback_commit = root_tag.fallback_commit,
                fallback_tag = root_tag.fallback_tag,
                fallback_branch = root_tag.fallback_branch,
                shallow_since = root_tag.shallow_since,
                init_submodules = root_tag.init_submodules,
                recursive_init_submodules = root_tag.recursive_init_submodules,
            )
            _check_template_collision(name, params)
            git_templates[name] = params

    if DEFAULT_VCPKG_ROOT_WORKSPACE_NAME not in http_templates and DEFAULT_VCPKG_ROOT_WORKSPACE_NAME not in git_templates:
        http_templates[DEFAULT_VCPKG_ROOT_WORKSPACE_NAME] = struct(
            kind = "http_archive",
            urls = ("https://github.com/microsoft/vcpkg/archive/refs/tags/2026.06.01.tar.gz",),
            sha256 = "d394626f9205790915c70e1281eb08554e8d72ac0677334893e32636ae08ec3d",
            strip_prefix = "vcpkg-2026.06.01",
        )

    for name, params in http_templates.items():
        http_archive(
            name = "vcpkg_root_%s" % name,
            urls = list(params.urls),
            sha256 = params.sha256,
            strip_prefix = params.strip_prefix,
            build_file_content = VCPKG_ROOT_BUILD_FILE,
        )

    git_synth_declared = {}

    def _resolve_root_for_source(source_name, source_root, baseline):
        if source_root in http_templates:
            if baseline != None:
                tpl = http_templates[source_root]
                fail(
                    ("vcpkg.source '{src}': manifest declares " +
                     "`builtin-baseline = \"{bl}\"`, but the selected root " +
                     "'{rt}' is a `root_http_archive` (urls={urls}). " +
                     "`http_archive` strips git metadata, so vcpkg can't " +
                     "read `versions/baseline.json` at that commit. " +
                     "Either remove `builtin-baseline` from the manifest, " +
                     "or declare the root via `vcpkg.root_git_repository`.").format(
                        src = source_name, bl = baseline, rt = source_root,
                        urls = list(tpl.urls),
                    ),
                )
            return "vcpkg_root_%s" % source_root

        tpl = git_templates[source_root]
        if baseline != None:
            ref, ref_kind = baseline, "commit"
        elif tpl.fallback_commit:
            ref, ref_kind = tpl.fallback_commit, "commit"
        elif tpl.fallback_tag:
            ref, ref_kind = tpl.fallback_tag, "tag"
        elif tpl.fallback_branch:
            ref, ref_kind = tpl.fallback_branch, "branch"
        else:
            fail(
                ("vcpkg.source '{src}': manifest has no " +
                 "`builtin-baseline` and the selected root '{rt}' has " +
                 "no `fallback_commit`, `fallback_tag`, or " +
                 "`fallback_branch`. Set one of those on the root tag " +
                 "or add a baseline to the manifest.").format(
                    src = source_name, rt = source_root,
                ),
            )
        repo_name = "vcpkg_root_{}__{}".format(source_root, _sanitise_ref(ref))
        if repo_name not in git_synth_declared:
            git_synth_declared[repo_name] = True
            _vcpkg_git_root_repo(
                name = repo_name,
                remote = tpl.remote,
                ref = ref,
                ref_kind = ref_kind,
                shallow_since = tpl.shallow_since,
                init_submodules = tpl.init_submodules,
                recursive_init_submodules = tpl.recursive_init_submodules,
            )
        return repo_name

    # Collect the (single) vcpkg.tool_from_upstream_release tag. Multiple tags
    # would be ambiguous, so fail if we see more than one.
    cli_version = _DEFAULT_VCPKG_TOOL_VERSION
    cli_shas = dict(_DEFAULT_VCPKG_TOOL_SHA256_PER_ASSET)
    cli_strict = True
    cli_tag_count = 0
    for mod in module_ctx.modules:
        for t in mod.tags.tool_from_upstream_release:
            cli_tag_count += 1
            if cli_tag_count > 1:
                fail("vcpkg: only one vcpkg.tool_from_upstream_release tag is supported per module graph.")
            cli_version = t.version
            cli_shas = dict(t.sha256_per_asset)
            cli_strict = t.strict_file_set

    if cli_strict:
        for asset in _DEFAULT_VCPKG_TOOL_SHA256_PER_ASSET.keys():
            if asset not in cli_shas:
                fail(
                    "vcpkg.tool_from_upstream_release: missing sha256 for asset " +
                    "'{}'. Either add it to `sha256_per_asset` or set " +
                    "`strict_file_set = False` to allow missing entries " +
                    "(host-specific lookups will still fail if the matching " +
                    "asset is absent).".format(asset),
                )

    host_asset = _vcpkg_cli_asset_for_host(module_ctx.os.name, module_ctx.os.arch)
    if host_asset not in cli_shas:
        fail(
            "vcpkg.tool_from_upstream_release: this host needs asset '{}' " +
            "but it is not listed in `sha256_per_asset`.".format(host_asset),
        )

    cli_repo_name = "vcpkg_cli"
    http_file(
        name = cli_repo_name,
        urls = [
            "https://github.com/microsoft/vcpkg-tool/releases/download/{}/{}".format(cli_version, host_asset),
        ],
        sha256 = cli_shas[host_asset],
        downloaded_file_path = "vcpkg.exe" if host_asset.endswith(".exe") else "vcpkg",
        executable = True,
    )

    # Hermetic cmake for fetch-time vcpkg invocations: reuse the same prebuilt
    # cmake spec rules_foreign_cc would set up via `prebuilt_toolchains`.
    cmake_spec_key = ("macos", "universal")
    os_l = module_ctx.os.name.lower()
    arch_l = module_ctx.os.arch.lower()
    if os_l.startswith("linux"):
        cmake_spec_key = ("linux", "aarch64" if "aarch64" in arch_l or "arm64" in arch_l else "x86_64")
    elif os_l.startswith("windows"):
        cmake_spec_key = ("windows", "x86_64")
    cmake_spec = CMAKE_BIN_SRCS.get(_DEFAULT_CMAKE_VERSION, {}).get(cmake_spec_key)
    if cmake_spec == None:
        fail("vcpkg: no prebuilt cmake spec for version {} on host {}-{}".format(
            _DEFAULT_CMAKE_VERSION, cmake_spec_key[0], cmake_spec_key[1],
        ))
    cmake_for_fetch_repo = "vcpkg_cmake_for_fetch"
    cmake_build_file = "exports_files([\"bin/{}\"])\n".format(cmake_spec.bin)
    http_archive(
        name = cmake_for_fetch_repo,
        urls = cmake_spec.urls,
        strip_prefix = cmake_spec.strip_prefix,
        sha256 = cmake_spec.sha256,
        build_file_content = cmake_build_file,
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
            if source.root not in http_templates and source.root not in git_templates:
                fail(
                    ("vcpkg.source '{}' references root '{}', which is not " +
                     "declared. Declare it via `vcpkg.root_http_archive` or " +
                     "`vcpkg.root_git_repository` in this module.").format(
                        source.name, source.root,
                    ),
                )
            baseline = _manifest_baseline(module_ctx, source.manifest)
            resolved_root_repo = _resolve_root_for_source(source.name, source.root, baseline)
            by_pkg = overrides_by_source.get(source.name, {})
            applicable = {}
            packages = sorted({p: True for p in (list(by_pkg.keys()) + list(defaults_by_package.keys()))}.keys())
            for pkg in packages:
                user_entries = by_pkg.get(pkg, [])
                default_entries = defaults_by_package.get(pkg, [])
                merged = _merged_overrides_for_package(user_entries, default_entries)
                if merged:
                    applicable[pkg] = {"entries": merged}

            # One capture repo per (source, triplet). Exposes `:all` for vcpkg_install.
            # `@<repo>//file:file` is a filegroup (rejects allow_single_file); use the
            # named downloaded_file_path instead.
            vcpkg_cli_basename = "vcpkg.exe" if host_asset.endswith(".exe") else "vcpkg"
            vcpkg_cli_label = "@{}//file:{}".format(cli_repo_name, vcpkg_cli_basename)
            cmake_bin_label = "@{}//:bin/{}".format(cmake_for_fetch_repo, cmake_spec.bin)
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
                    vcpkg_root_marker = "@{}//:.vcpkg-root".format(resolved_root_repo),
                    vcpkg_cli = vcpkg_cli_label,
                    cmake_bin = cmake_bin_label,
                )
                downloads_by_triplet[triplet] = "@{}//:all".format(capture_repo)

            vcpkg_repo(
                name = source.name,
                manifest = source.manifest,
                vcpkg_configuration = source.vcpkg_configuration,
                overlay_ports = source.overlay_ports,
                overlay_triplets = source.overlay_triplets,
                vcpkg_root = resolved_root_repo,
                vcpkg_root_marker = "@{}//:.vcpkg-root".format(resolved_root_repo),
                overrides_json = json.encode(applicable),
                triplet_mappings_json = json.encode(triplet_mappings),
                downloads_by_triplet_json = json.encode(downloads_by_triplet),
                vcpkg_cli = vcpkg_cli_label,
                cmake_bin = cmake_bin_label,
            )
    return None

# TODO(TheGrizzlyDev): automatically use the right triplet for a given platform
vcpkg = module_extension(
    implementation = _vcpkg_mod,
    tag_classes = {
        "root_http_archive": vcpkg_root_http_archive,
        "root_git_repository": vcpkg_root_git_repository,
        "tool_from_upstream_release": vcpkg_tool_from_upstream_release,
        "source": vcpkg_source,
        "package_override": vcpkg_package_override,
        "triplet_mapping": vcpkg_triplet_mapping,
    }
)