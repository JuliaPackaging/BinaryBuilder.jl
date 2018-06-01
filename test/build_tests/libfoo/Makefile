all: install

# We provide sane defaults, but BinaryBuilder may override most of these values.
prefix ?= /usr/local
bindir ?= $(prefix)/bin
libdir ?= $(prefix)/lib
CC ?= gcc

ifeq ($(shell uname),Darwin)
CFLAGS = -target x86_64-apple-macosx10.7
INSTALL_NAME ?= -install_name '@rpath/libfoo.$(SHLIB_EXT)'
SHLIB_EXT ?= dylib
RPATH ?= -Wl,-rpath,'@executable_path/../lib' -Wl,-rpath,'@executable_path'
else ifneq ($(findstring MSYS,$(shell uname)),)
libdir ?= $(bindir)
SHLIB_EXT ?= dll
EXE_EXT ?= .exe
else
SHLIB_EXT ?= so
RPATH ?= -Wl,-rpath,'$$ORIGIN/../lib' -Wl,-rpath,'$$ORIGIN'
endif

$(bindir):
	mkdir -p $(bindir)
$(libdir):
	mkdir -p $(libdir)

# We explicitly do not have `fooifier` depend on `libfoo` so that the user has
# to make first libfoo and then `fooifier`, in order to properly test that
# BinaryBuilder can build dependent objects
fooifier$(EXE_EXT): fooifier.c Makefile | libfoo
	$(CC) $(CFLAGS) fooifier.c -g -o $@ -L"$(shell pwd)" $(RPATH) -lfoo
install-fooifier: $(bindir) fooifier$(EXE_EXT)
	cp fooifier$(EXE_EXT) $(bindir)/


libfoo.$(SHLIB_EXT): libfoo.c Makefile
	$(CC) $(CFLAGS) libfoo.c -g -o $@ $(INSTALL_NAME) -shared
libfoo: libfoo.$(SHLIB_EXT)
install-libfoo: $(libdir) libfoo.$(SHLIB_EXT)
	cp libfoo.$(SHLIB_EXT) $(libdir)/

install: install-fooifier install-libfoo

clean:
	rm -rf fooifier fooifier.exe fooifier.dSYM
	rm -rf libfoo.so libfoo.dll libfoo.dylib libfoo.dylib.dSYM

.SUFFIXES:
