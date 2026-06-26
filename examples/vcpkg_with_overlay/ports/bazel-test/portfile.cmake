set(VCPKG_POLICY_EMPTY_PACKAGE enabled)

file(INSTALL
    "${CMAKE_CURRENT_LIST_DIR}/bazel_test.h"
    DESTINATION "${CURRENT_PACKAGES_DIR}/include")

file(WRITE "${CURRENT_PACKAGES_DIR}/share/${PORT}/copyright" "MIT\n")
