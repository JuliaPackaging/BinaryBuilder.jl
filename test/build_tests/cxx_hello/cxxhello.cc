#include "common.h"
#include <iostream>

int main(int argc, const char ** argv) {
    std::string msg = say_hello(std::string(argv[argc-1]));
    int result = add(7, argc);

    std::cout << msg << result << std::endl;
    return 0;
}
