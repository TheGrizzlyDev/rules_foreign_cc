#include <bazel_test.h>
#include <cstdio>

int main() {
  std::printf("%s\n", BAZEL_TEST_GREETING);
  return 0;
}
