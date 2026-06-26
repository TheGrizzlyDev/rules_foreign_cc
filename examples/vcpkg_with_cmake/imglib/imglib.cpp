#include "imglib.h"

#include <png.h>
#include <zlib.h>

#include <cstdio>
#include <string>

namespace imglib {

const char* describe() {
  // Force real calls into both libraries so the link genuinely depends on
  // them, not just on their headers.
  png_structp png =
      png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
  if (png) png_destroy_write_struct(&png, nullptr);

  static std::string s;
  s.clear();
  s.append("libpng ");
  s.append(png_libpng_ver);
  s.append(" + zlib ");
  s.append(zlibVersion());
  return s.c_str();
}

}  // namespace imglib
