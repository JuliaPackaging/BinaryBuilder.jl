# Specify the minimum version for CMake
cmake_minimum_required(VERSION 3.10)

add_library(libfoo SHARED libfoo.c)

add_executable(fooifier fooifier.cpp)
target_link_libraries(fooifier libfoo)
