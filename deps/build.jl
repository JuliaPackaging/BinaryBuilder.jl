using BinaryBuilder

# Build the sandbox binary
BinaryBuilder.update_sandbox_binary()

# Initialize just linux64, everything else will be downloaded on-demand
BinaryBuilder.update_rootfs(triplet.([Linux(:x86_64)]); verbose=true)
