using BinaryBuilder

# On travis, default to using the squashfs image for disk space concerns
# Ideally, we'd just use the squashfs image everywhere, but mounting it requires
# root privileges and cannot be done from inside the sandbox. Once that changes
# in future kernel versions, we'll be able to get rid of the .tar.gz version.
squashfs = get(ENV, "TRAVIS", "") == "true" &&
           !(get(ENV, "TESTING_BINARYBUILDER_TAR_GZ", "false") == "true")

# Initialize our rootfs and sandbox blobs
BinaryBuilder.update_rootfs(; squashfs=squashfs)
BinaryBuilder.update_sandbox_binary()

# Automatically mount the squashfs image (requires root priviliges)
if squashfs
    mkpath(BinaryBuilder.rootfs)
    run(`sudo mount $(BinaryBuilder.rootfs_base).squash $(BinaryBuilder.rootfs) -o ro,loop`)
end
