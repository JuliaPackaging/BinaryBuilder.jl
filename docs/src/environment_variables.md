# Environment Variables

`BinaryBuilder.jl` supports multiple environment variables to modify its behavior globally:

* `BINARYBUILDER_AUTOMATIC_APPLE`: when set to `true`, this automatically agrees to the Apple macOS SDK license agreement, enabling the building of binary objects for macOS systems.

* `BINARYBUILDER_USE_SQUASHFS`: when set to `true`, this uses `.squashfs` images instead of tarballs to download cross-compiler shards.  This consumes significantly less space on-disk and boasts a modest reduction in download size as well, but requires `sudo` on the local machine to mount the `.squashfs` images.  This is used by default on Travis, as the disk space requirements are tight.

* `BINARYBUILDER_DOWNLOADS_CACHE`: When set to a path, cross-compiler shards will be downloaded to this location, instead of the default location of `<binarybuilder_root>/deps/downloads`.

* `BINARYBUILDER_ROOTFS_DIR`: When set to a path, the base root FS will be unpacked/mounted to this location, instead of the default location of `<binarybuilder_root>/deps/root`.

* `BINARYBUILDER_SHARDS_DIR`: When set to a path, cross-compiler shards will be unpacked/mounted to this location, instead of the default location of `<binarybuilder_root>/deps/shards`.