using BinaryBuilder

# Build the sandbox binary
BinaryBuilder.update_sandbox_binary()

# Initialize just a few platforms here, let the others get brought in on demand
t = triplet.([Linux(:x86_64), MacOS(:x86_64), Windows(:x86_64)])
BinaryBuilder.update_rootfs(t; verbose=true)
