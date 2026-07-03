"""Built-in `vcpkg.package_override` defaults applied by the module extension.

Each entry has the same shape as a user `vcpkg.package_override` tag, plus
a mandatory `package` key. The extension drops a default whenever any user
entry for the same package covers it.

Static-library entries were derived by inspecting the .list files vcpkg
ships under `<install>/vcpkg/info/<pkg>_<version>_<triplet>.list` for a
concrete install tree (arm64-osx). Ports whose lib basenames match the
`<pkg>` or `lib<pkg>` heuristic aren't listed here; add an override only
when the port ships libs that diverge from the port name.
"""

DEFAULT_PACKAGE_OVERRIDES = [
    # Ports whose lib basename diverges from `<pkg>` / `<pkg without lib>`.
    {"package": "abseil", "out_static_libs": [
        "absl_base", "absl_borrowed_fixup_buffer", "absl_city", "absl_civil_time",
        "absl_cord", "absl_cord_internal", "absl_cordz_functions",
        "absl_cordz_handle", "absl_cordz_info", "absl_cordz_sample_token",
        "absl_crc_cord_state", "absl_crc_cpu_detect", "absl_crc_internal",
        "absl_crc32c", "absl_debugging_internal", "absl_decode_rust_punycode",
        "absl_demangle_internal", "absl_demangle_rust", "absl_die_if_null",
        "absl_examine_stack", "absl_exponential_biased",
        "absl_failure_signal_handler", "absl_flags_commandlineflag",
        "absl_flags_commandlineflag_internal", "absl_flags_config",
        "absl_flags_internal", "absl_flags_marshalling", "absl_flags_parse",
        "absl_flags_private_handle_accessor", "absl_flags_program_name",
        "absl_flags_reflection", "absl_flags_usage", "absl_flags_usage_internal",
        "absl_generic_printer_internal", "absl_graphcycles_internal", "absl_hash",
        "absl_hashtable_profiler", "absl_hashtablez_sampler", "absl_int128",
        "absl_kernel_timeout_internal", "absl_leak_check", "absl_log_entry",
        "absl_log_flags", "absl_log_globals", "absl_log_initialize",
        "absl_log_internal_check_op", "absl_log_internal_conditions",
        "absl_log_internal_fnmatch", "absl_log_internal_format",
        "absl_log_internal_globals", "absl_log_internal_log_sink_set",
        "absl_log_internal_message", "absl_log_internal_nullguard",
        "absl_log_internal_proto", "absl_log_internal_structured_proto",
        "absl_log_severity", "absl_log_sink", "absl_malloc_internal",
        "absl_periodic_sampler", "absl_poison", "absl_profile_builder",
        "absl_random_distributions",
        "absl_random_internal_distribution_test_util",
        "absl_random_internal_entropy_pool", "absl_random_internal_platform",
        "absl_random_internal_randen", "absl_random_internal_randen_hwaes",
        "absl_random_internal_randen_hwaes_impl",
        "absl_random_internal_randen_slow", "absl_random_internal_seed_material",
        "absl_random_seed_gen_exception", "absl_random_seed_sequences",
        "absl_raw_hash_set", "absl_raw_logging_internal", "absl_scoped_set_env",
        "absl_spinlock_wait", "absl_stacktrace", "absl_status", "absl_statusor",
        "absl_str_format_internal", "absl_strerror", "absl_strings",
        "absl_strings_internal", "absl_symbolize", "absl_synchronization",
        "absl_throw_delegate", "absl_time", "absl_time_zone",
        "absl_tracing_internal", "absl_utf8_for_code_point",
        "absl_vlog_config_internal",
    ]},
    {"package": "angle", "out_static_libs": ["EGL_angle", "GLESv2_angle"]},
    {"package": "brotli", "out_static_libs": ["brotlicommon", "brotlidec", "brotlienc"]},
    {"package": "bzip2", "out_static_libs": ["bz2"]},
    {"package": "ffmpeg", "out_static_libs": [
        "avcodec", "avdevice", "avfilter", "avformat", "avutil",
        "swresample", "swscale",
    ]},
    {"package": "gettext-libintl", "out_static_libs": ["intl"]},
    {"package": "giflib", "out_static_libs": ["gif"]},
    {"package": "harfbuzz", "out_static_libs": ["harfbuzz", "harfbuzz-icu", "harfbuzz-subset"]},
    {"package": "highway", "out_static_libs": ["hwy"]},
    {"package": "icu", "out_static_libs": ["icudata", "icui18n", "icuio", "icutu", "icuuc"]},
    {"package": "lcms", "out_static_libs": ["lcms2"]},
    {"package": "libavif", "out_static_libs": ["avif"]},
    {"package": "libdwarf", "out_static_libs": ["dwarf"]},
    {"package": "libedit", "out_static_libs": ["edit"]},
    {"package": "libidn2", "out_static_libs": ["idn2"]},
    {"package": "libjpeg-turbo", "out_static_libs": ["jpeg", "turbojpeg"]},
    {"package": "libjxl", "out_static_libs": ["jxl", "jxl_cms", "jxl_threads"]},
    {"package": "liblzma", "out_static_libs": ["lzma"]},
    {"package": "libogg", "out_static_libs": ["ogg"]},
    {"package": "libpng", "out_static_libs": ["png", "png16"]},
    {"package": "libpsl", "out_static_libs": ["psl"]},
    {"package": "libtheora", "out_static_libs": ["theora", "theoradec", "theoraenc"]},
    {"package": "libtommath", "out_static_libs": ["tommath"]},
    {"package": "libunistring", "out_static_libs": ["unistring"]},
    {"package": "libvorbis", "out_static_libs": ["vorbis", "vorbisenc", "vorbisfile"]},
    {"package": "libvpx", "out_static_libs": ["vpx"]},
    {"package": "libwebp", "out_static_libs": [
        "sharpyuv", "webp", "webpdecoder", "webpdemux", "webpmux",
    ]},
    {"package": "libxml2", "out_static_libs": ["xml2"]},
    {"package": "libyuv", "out_static_libs": ["yuv"]},
    {"package": "ngtcp2", "out_static_libs": ["ngtcp2", "ngtcp2_crypto_ossl"]},
    {"package": "openssl", "out_static_libs": ["crypto", "ssl"]},
    {"package": "sdl3", "out_static_libs": ["SDL3"]},
    {"package": "skia", "out_static_libs": [
        "bentleyottmann", "jsonreader", "skia", "skottie", "skparagraph",
        "sksg", "skshaper", "skunicode_core", "skunicode_icu", "svg",
    ]},
    {"package": "woff2", "out_static_libs": ["woff2common", "woff2dec", "woff2enc"]},
    {"package": "zlib", "out_static_libs": ["z"]},

    # jsoncpp `d`-suffix opt-out (see prior override behaviour).
    {"package": "jsoncpp", "compilation_mode": "dbg", "out_static_libs": ["$$VCPKG_PACKAGE$$"]},

    # vcpkg-namespace helpers + registry-header ports: no consumable libs.
    {"package": "dirent", "out_headers_only": True},
    {"package": "egl-registry", "out_headers_only": True},
    {"package": "fast-float", "out_headers_only": True},
    {"package": "gettext", "out_headers_only": True},
    {"package": "gperf", "out_headers_only": True},
    {"package": "libiconv", "out_headers_only": True},
    {"package": "libproxy", "out_headers_only": True},
    {"package": "opengl-registry", "out_headers_only": True},
    {"package": "pdfjs", "out_headers_only": True},
    {"package": "pthread", "out_headers_only": True},
    {"package": "pthreads", "out_headers_only": True},
    {"package": "vcpkg-cmake", "out_headers_only": True},
    {"package": "vcpkg-cmake-config", "out_headers_only": True},
    {"package": "vcpkg-cmake-get-vars", "out_headers_only": True},
    {"package": "vcpkg-get-python-packages", "out_headers_only": True},
    {"package": "vcpkg-gn", "out_headers_only": True},
    {"package": "vcpkg-make", "out_headers_only": True},
    {"package": "vcpkg-msbuild", "out_headers_only": True},
    {"package": "vcpkg-pkgconfig-get-modules", "out_headers_only": True},
    {"package": "vcpkg-tool-gn", "out_headers_only": True},
    {"package": "vcpkg-tool-meson", "out_headers_only": True},
    {"package": "wuffs", "out_headers_only": True},
]
