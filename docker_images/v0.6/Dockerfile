FROM julia:0.6

# Install tools which get used by BinaryBuilder.
RUN apt-get update && apt-get install -y xz-utils

RUN cd /usr/local/bin && \
    curl -L 'https://github.com/tcnksm/ghr/releases/download/v0.10.0/ghr_v0.10.0_linux_amd64.tar.gz' -o- | tar -zx --strip-components=1

# Set useful envvars
ENV BINARYBUILDER_USE_SQUASHFS true
ENV BINARYBUILDER_DOWNLOADS_CACHE /shards
ENV BINARYBUILDER_CCACHE_PATH /ccache
ENV BINARYBUILDER_AUTOMATIC_APPLE true
ENV BINARYBUILDER_USE_CCACHE true

# we'll make this even though the user should mount something in here
RUN mkdir -p /shards

# Install BinaryBuilder
RUN julia -e 'Pkg.clone("https://github.com/JuliaPackaging/BinaryBuilder.jl.git"); using BinaryBuilder'

# The user should mount something in /ccache and /shards so they persist from run to run
