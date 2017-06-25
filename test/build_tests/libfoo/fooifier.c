#include <stdio.h>
#include <stdlib.h>

double foo(double a, double b);

int main(int argc, char * argv[]) {
    if( argc != 3 ) {
        printf("Usage: %s <a> <b>\n", argv[0]);
        printf("  Returns: 2*a^2 - b\n");
        return 1;
    }

    double a = atof(argv[1]);
    double b = atof(argv[2]);
    double result = foo(a, b);

    printf("%f\n", result);

    return 0;
}
