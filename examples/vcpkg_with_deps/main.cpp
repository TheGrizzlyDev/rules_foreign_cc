// Exercises libpng -> zlib link dependency.  libpng's compression path
// pulls in zlib symbols (deflateInit_, etc.); if vcpkg_deps_by_triplet
// hasn't wired libpng -> zlib, this won't link.

#include <png.h>
#include <zlib.h>
#include <cstdio>

int main() {
  std::printf("libpng: %s\n", png_libpng_ver);
  std::printf("zlib:   %s\n", zlibVersion());

  // Force a real call into the libpng compression path so we know the
  // zlib symbols were actually resolved at link time, not just declared.
  png_structp png =
      png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
  if (!png) return 1;
  png_infop info = png_create_info_struct(png);
  if (!info) {
    png_destroy_write_struct(&png, nullptr);
    return 1;
  }
  png_destroy_write_struct(&png, &info);
  return 0;
}
