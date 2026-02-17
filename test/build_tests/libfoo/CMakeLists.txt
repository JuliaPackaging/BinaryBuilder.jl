# Specify the minimum version for CMake
cmake_minimum_required(VERSION 3.10)

add_library(foo SHARED libfoo.c)
add_library(fooFramework SHARED libfoo.c)

add_executable(fooifier fooifier.cpp)
target_link_libraries(fooifier foo)

# Enable relative RPATH
if (APPLE)
    set_target_properties(fooifier PROPERTIES INSTALL_RPATH "@executable_path/../lib")
    set_target_properties(fooFramework PROPERTIES FRAMEWORK TRUE FRAMEWORK_VERSION C)
elseif (UNIX)
    set_target_properties(fooifier PROPERTIES INSTALL_RPATH "$ORIGIN/../lib")
endif()

install(FILES libfoo.pc DESTINATION lib/pkgconfig)
install(TARGETS foo DESTINATION lib)
install(TARGETS fooFramework DESTINATION lib)
install(TARGETS fooifier RUNTIME DESTINATION bin)

