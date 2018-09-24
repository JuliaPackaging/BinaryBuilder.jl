#include <iostream>
#include <stdlib.h>

using namespace std;

extern "C" {
    double foo(double a, double b);
}

int main(int argc, char * argv[]) {
    if( argc != 3 ) {
        cout << "Usage: " << argv[0] << " <a> <b>\n";
        cout << "  Returns: 2*a^2 - b\n";
        return 1;
    }

    double a = atof(argv[1]);
    double b = atof(argv[2]);
    double result = foo(a, b);

    cout << result << "\n";

    return 0;
}
