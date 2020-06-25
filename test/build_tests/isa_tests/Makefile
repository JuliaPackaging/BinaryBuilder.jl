prefix ?= /usr/local
bindir ?= $(prefix)/bin
CC ?= gcc

all: main_avx512 main_avx2 main_avx main_sse

main_avx512: main.c
	$(CC) -o main_avx512 -march=skylake-avx512 -O3 main.c

main_avx2: main.c
	$(CC) -o main_avx2 -march=haswell -O3 main.c

main_avx: main.c
	$(CC) -o main_avx -march=sandybridge -O3 main.c

main_sse: main.c
	$(CC) -o main_sse -march=core2 -O3 main.c

install: main_avx512 main_avx2 main_avx main_sse
	mkdir -p $(bindir)
	cp main_* $(bindir)/

clean:
	rm -f main_*
