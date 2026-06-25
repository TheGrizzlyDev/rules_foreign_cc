#include <bzlib.h>
#include <cstdio>

int main() {
  std::printf("bzip2: %s\n", BZ2_bzlibVersion());
  return 0;
}
