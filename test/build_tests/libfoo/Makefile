all: fooifier

ifeq ($(shell uname),Darwin)
RPATH := -Wl,-rpath,'@executable_path/../lib' -Wl,-rpath,'@executable_path'
INSTALL_NAME = -install_name '@rpath/libfoo.dylib'
else ifneq ($(findstring MSYS,$(shell uname)),)
RPATH :=
else
RPATH := -Wl,-rpath,'$$ORIGIN/../lib' -Wl,-rpath,'$$ORIGIN'
endif

$(bindir):
	mkdir -p $(bindir)
$(libdir):
	mkdir -p $(libdir)

fooifier$(exeext): fooifier.cpp Makefile | libfoo
	$(CXX) $(CXXFLAGS) fooifier.cpp -g -o $@ -L"$(shell pwd)" $(LDFLAGS) $(RPATH) -lfoo
install-fooifier: $(bindir) fooifier$(exeext)
	cp fooifier$(exeext) $(bindir)/


libfoo.$(dlext): libfoo.c Makefile
	$(CC) $(CFLAGS) libfoo.c -g -o $@ $(LDFLAGS) -shared $(INSTALL_NAME)
libfoo: libfoo.$(dlext)
install-libfoo: $(libdir) libfoo.$(dlext)
	cp libfoo.$(dlext) $(libdir)/

install: install-fooifier install-libfoo

clean:
	rm -rf fooifier fooifier.exe fooifier.dSYM
	rm -rf libfoo.so libfoo.dll libfoo.dylib libfoo.dylib.dSYM

.SUFFIXES:
