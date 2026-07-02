#include <fmt/core.h>
#include <zlib.h>

int main() {
  fmt::print("zlib version: {}\n", zlibVersion());
  return 0;
}
