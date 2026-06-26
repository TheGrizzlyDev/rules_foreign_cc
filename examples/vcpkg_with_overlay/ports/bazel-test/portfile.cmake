set(VCPKG_POLICY_EMPTY_PACKAGE enabled)

file(INSTALL
    "${CMAKE_CURRENT_LIST_DIR}/bazel_test.h"
    DESTINATION "${CURRENT_PACKAGES_DIR}/include")

# Ship a tiny tool binary so we can exercise out_binaries end-to-end.
# vcpkg layout requires tools under tools/<port>/.
file(WRITE "${CURRENT_PACKAGES_DIR}/tools/${PORT}/greet"
    "#!/bin/sh\necho \"greetings from bazel-test\"\n")
file(CHMOD "${CURRENT_PACKAGES_DIR}/tools/${PORT}/greet"
    PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                GROUP_READ GROUP_EXECUTE
                WORLD_READ WORLD_EXECUTE)

file(WRITE "${CURRENT_PACKAGES_DIR}/share/${PORT}/copyright" "MIT\n")
