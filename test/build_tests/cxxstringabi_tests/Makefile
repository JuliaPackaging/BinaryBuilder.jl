all: libcxxstringabi_test.$(dlext)

$(libdir):
	mkdir -p $(libdir)

libcxxstringabi_test.$(dlext): lib.cc Makefile
	$(CXX) $(CFLAGS) -fPIC $< -g -o $@ $(LDFLAGS) -shared
install: $(libdir) libcxxstringabi_test.$(dlext)
	cp libcxxstringabi_test.$(dlext) $(libdir)/

clean:
	rm -rf libcxxstringabi_test.so libcxxstringabi_test.dll libcxxstringabi_test.dylib libcxxstringabi_test.dylib.dSYM

.SUFFIXES:
