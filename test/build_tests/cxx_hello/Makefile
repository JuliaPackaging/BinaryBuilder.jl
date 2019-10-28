CXX ?= g++
ifeq ($(shell uname),Darwin)
dlext ?= dylib
else ifneq ($(findstring MSYS,$(shell uname)),)
dlext ?= dll
else
dlext ?= so
endif

USE_CXX11 ?= 1

ifeq ($(USE_CXX11),1)
	CXXFLAGS += -D_GLIBCXX_USE_CXX11_ABI=1
else
	CXXFLAGS += -D_GLIBCXX_USE_CXX11_ABI=0
endif

all: libcxxhello cxxhello

libcxxhello: libcxxhello.$(dlext)
libcxxhello.$(dlext): libcxxhello.cc
	$(CXX) $(CXXFLAGS) -shared -o $@ -O2 libcxxhello.cc

cxxhello: cxxhello.cc
	$(CXX) $(CXXFLAGS) -o $@ -O2 cxxhello.cc -L. -lcxxhello

.SUFFIXES:

clean:
	rm -f libcxxhello.$(dlext) cxxhello
