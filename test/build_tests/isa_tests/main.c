#include <stdio.h>
#include <stdlib.h>

#define ELTYPE float
#define STRIDE 16

ELTYPE summation(ELTYPE * data, int length) {
    ELTYPE sum = 0;
    for( int idx=0; idx<length/STRIDE; ++idx ) {
        for( int jdx=0; jdx<STRIDE; ++jdx ) {
            sum += data[idx + jdx];
        }
    }
    return sum;
}


int main(int argc, char ** argv) {
    if( argc <= 1 ) {
        printf("Usage: %s <length>\n  Where length must be divisible by %d\n", argv[0], STRIDE);
        return 1;
    }
    int length = atoi(argv[1]);
    if( length % STRIDE != 0 ) {
        printf("length (%d) must be divisible by %d!\n", length, STRIDE);
        return 1;
    }

    ELTYPE * data = (ELTYPE *) malloc(sizeof(ELTYPE)*length);
    for( int idx = 0; idx<length; ++idx ) {
        data[idx] = (ELTYPE)(idx*idx);
    }
    ELTYPE sum = summation(data, length);
    printf("Sum of x^2 over [0, %d]: %f\n", length, sum);
    return 0;
}
   
