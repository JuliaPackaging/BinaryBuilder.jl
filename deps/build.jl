using BinaryBuilder

# On travis, default to using the squashfs image for disk space concerns
# Ideally, we'd just use the squashfs image everywhere, but mounting it requires
# root privileges and cannot be done from inside the sandbox. Once that changes
# in future kernel versions, we'll be able to get rid of the .tar.gz version.
squashfs = get(ENV, "TRAVIS", "") == "true" &&
           !(get(ENV, "TESTING_BINARYBUILDER_TAR_GZ", "false") == "true")
automatic = get(ENV, "TRAVIS", "") == "true"

# Build the sandbox binary
BinaryBuilder.update_sandbox_binary()

# Initialize just a few platforms here, let the others get brought in on demand
for pt in triplet.([Linux(:x86_64), MacOS(:x86_64), Windows(:x86_64)])
    BinaryBuilder.update_rootfs(pt; automatic=automatic, squashfs=squashfs, verbose=true)
end