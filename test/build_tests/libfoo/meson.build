project('foo', 'cpp')
add_languages('c')

libfoo = shared_library('foo', 'libfoo.c',
			version : '1.2.3', soversion : '0',
			install : true)

# Set rpath directories for macOS and Linux, defaulting to nothing
rpath_dir = ''
if host_machine.system() == 'darwin'
  rpath_dir = '@executable_path/../lib'
elif host_machine.system() == 'linux'
  rpath_dir = '$ORIGIN/../lib'
endif

executable('fooifier', 'fooifier.cpp',
	   link_with : libfoo, install : true,
	   install_rpath : rpath_dir)
