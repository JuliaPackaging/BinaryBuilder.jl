#include <string>
#include <list>

std::string my_name() {
    return std::string("Bob The Binary Builder");
}

int my_strlen(std::string str) {
    return str.length();
}

int my_listlen(std::list<int> x) {
    return x.size();
}
