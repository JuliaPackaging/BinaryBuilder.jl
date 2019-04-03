# Environment Variables

`BinaryBuilder.jl` supports multiple environment variables to modify its behavior globally:

* `BINARYBUILDER_AUTOMATIC_APPLE`: when set to `true`, this automatically agrees to the Apple macOS SDK license agreement, enabling the building of binary objects for macOS systems.

* `BINARYBUILDER_USE_SQUASHFS`: when set to `true`, this uses `.squashfs` images instead of tarballs to download cross-compiler shards.  This consumes significantly less space on-disk and boasts a modest reduction in download size as well, but requires `sudo` on the local machine to mount the `.squashfs` images.  This is used by default on Travis, as the disk space requirements are tight.  This is always used on OSX, as the QEMU runner always uses `squashfs` images.

* `BINARYBUILDER_STORAGE_DIR`: When set to a path, storage for things like cross-compiler shards, downloaded source tarballs, the QEMU binaries, the `ccache` cache, etc... will be stored within this location, instead of the default location of `<binarybuilder_root>/deps/`.

* `BINARYBUILDER_RUNNER`: When set to a runner string, alters the execution engine that `BinaryBuilder.jl` will use to wrap the build process in a sandbox.  Valid values are one of `"userns"`, `"privileged"` and `"qemu"`.  If not given, `BinaryBuilder.jl` will do its best to guess.

* `BINARYBUILDER_ALLOW_ECRYPTFS`: When set to `true`, this allows the mounting of rootfs/shard/workspace directories from within encrypted mounts.  This is disabled by default, as at the time of writing, this triggers kernel bugs.  To avoid these kernel bugs on a system where e.g. the home directory has been encrypted, set the `BINARYBUILDER_ROOTFS_DIR` and `BINARYBUILDER_SHARDS_DIR` environment variables to a path outside of the encrypted home directory.

* `BINARYBUILDER_USE_CCACHE`: When set to `true`, this causes a `/root/.ccache` volume to be mounted within the build environment, and for the `CC`, `CXX` and `FC` environment variables to have `ccache` prepended to them.  This can significantly accelerate rebuilds of the same package on the same host.  Note that `ccache` will, by default, store 5G of cached data.
