FROM julia:0.6

# Install tools which get used by BinaryBuilder.
RUN apt-get update && apt-get install -y xz-utils

# Set useful envvars
ENV BINARYBUILDER_USE_SQUASHFS true
ENV BINARYBUILDER_DOWNLOADS_CACHE /shards
ENV BINARYBUILDER_AUTOMATIC_APPLE true
ENV BINARYBUILDER_USE_CCACHE true

# we'll make this even though the user should mount something in here
RUN mkdir -p /shards

# Install BinaryBuilder
RUN julia -e 'Pkg.clone("https://github.com/JuliaPackaging/BinaryBuilder.jl.git"); using BinaryBuilder'

# The user should mount something in /root/.ccache and /shards
