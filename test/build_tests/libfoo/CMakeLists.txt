# Specify the minimum version for CMake
cmake_minimum_required(VERSION 3.10)

add_library(foo SHARED libfoo.c)

add_executable(fooifier fooifier.cpp)
target_link_libraries(fooifier foo)

# Enable relative RPATH
set_target_properties(fooifier PROPERTIES INSTALL_RPATH "$ORIGIN/../lib:$ORIGIN/")

install(TARGETS foo DESTINATION lib)
install(TARGETS fooifier RUNTIME DESTINATION bin)

