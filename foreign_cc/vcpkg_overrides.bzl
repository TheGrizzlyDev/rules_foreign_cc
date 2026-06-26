"""Built-in `vcpkg.package_override` defaults applied by the module extension.

Each entry has the same shape as a user `vcpkg.package_override` tag, plus
a mandatory `package` key. The extension drops a default whenever any user
entry for the same package covers it.
"""

DEFAULT_PACKAGE_OVERRIDES = [
    {"package": "bzip2", "out_static_libs": ["bz2"]},
    {"package": "libpng", "out_static_libs": ["png16"]},
    {"package": "zlib", "out_static_libs": ["z"]},
    {"package": "jsoncpp", "compilation_mode": "dbg", "out_static_libs": ["$$VCPKG_PACKAGE$$"]},
    {"package": "vcpkg-cmake", "out_headers_only": True},
    {"package": "vcpkg-cmake-config", "out_headers_only": True},
]
