prefix ?= /usr/local
bindir ?= $(prefix)/bin
CC ?= gcc

all: main

main: main.c
	$(CC) $(CFLAGS) -o $@ -O3 $^

install: main
	mkdir -p $(bindir)
	cp $^ $(bindir)/

clean:
	rm -f main
