project('foo', 'cpp')
add_languages('c')
libfoo = shared_library('foo', 'libfoo.c', version : '1.2.3', soversion : '0')
executable('fooifier', 'fooifier.cpp', link_with : libfoo)
