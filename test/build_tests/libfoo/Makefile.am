ACLOCAL_AMFLAGS = -I m4

lib_LTLIBRARIES = libfoo.la
libfoo_la_SOURCES = libfoo.c
libfoo_la_LDFLAGS = -no-undefined

bin_PROGRAMS = fooifier
fooifier_SOURCES = fooifier.cpp
fooifier_LDADD = libfoo.la
