#include <bzlib.h>
#include <cstdio>

// VCPKG_BZIP2_NAME and VCPKG_BZIP2_TRIPLET are emitted by the bzip2
// vcpkg.package_override in examples/MODULE.bazel, with $$VCPKG_PACKAGE$$
// and $$VCPKG_TRIPLET$$ placeholders substituted at analysis time.
int main() {
  std::printf("bzip2 %s (vcpkg package=%s, triplet=%s)\n",
              BZ2_bzlibVersion(), VCPKG_BZIP2_NAME, VCPKG_BZIP2_TRIPLET);
  return 0;
}
