prefix ?= /usr/local
bindir ?= $(prefix)/bin
CC ?= gcc

all: main

main: main.c
	$(CC) -o main -O3 main.c

install: main
	mkdir -p $(bindir)
	cp main $(bindir)/

clean:
	rm -f main*
