all: main_avx2 main_avx main_sse

main_avx2: main.c
	gcc -o main_avx2 -march=skylake-avx512 -O3 main.c

main_avx: main.c
	gcc -o main_avx -march=sandybridge -O3 main.c

main_sse: main.c
	gcc -o main_sse -march=core2 -O3 main.c

install: main_avx2 main_avx main_sse
	mkdir -p $(prefix)/bin
	cp main_* $(prefix)/bin

clean:
	rm -f main_*
