FROM julia:1.0

# Install tools which get used by BinaryBuilder.
RUN apt-get update && apt-get install -y xz-utils

RUN cd /usr/local/bin && \
    curl -L 'https://github.com/tcnksm/ghr/releases/download/v0.10.0/ghr_v0.10.0_linux_amd64.tar.gz' -o- | tar -zx --strip-components=1

# Set useful envvars
ENV BINARYBUILDER_USE_SQUASHFS true
ENV BINARYBUILDER_STORAGE_DIR /storage
ENV BINARYBUILDER_AUTOMATIC_APPLE true
ENV BINARYBUILDER_USE_CCACHE true

# we'll make this even though the user should mount something in here
RUN mkdir -p /storage

# Install BinaryBuilder (and BinaryProvider, both on `master` versions)
RUN julia -e 'using Pkg; Pkg.add(PackageSpec(name="BinaryProvider", rev="master"))'
RUN julia -e 'using Pkg; Pkg.add(PackageSpec(name="BinaryBuilder", rev="master"))'
RUN julia -e 'using Pkg; Pkg.API.precompile();'

# The user should mount something in /storage so that it persists from run to run
