cmake_minimum_required(VERSION 3.20)
project(imglib CXX)

find_package(PNG REQUIRED)

add_library(imglib STATIC imglib.cpp)
target_link_libraries(imglib PUBLIC PNG::PNG)
target_include_directories(imglib PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

include(GNUInstallDirs)
install(TARGETS imglib
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(FILES imglib.h
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
