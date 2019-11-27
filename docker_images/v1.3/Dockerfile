FROM julia:1.3

# Install tools which get used by BinaryBuilder.
RUN apt-get update && apt-get install -y xz-utils bzip2 sudo git unzip

# Set up default `git` username and email
RUN git config --global user.name "jlbuild"
RUN git config --global user.email "juliabuildbot@gmail.com"

# Set useful envvars
ENV BINARYBUILDER_USE_SQUASHFS true
ENV BINARYBUILDER_AUTOMATIC_APPLE true
ENV BINARYBUILDER_USE_CCACHE true
ENV BINARYBUILDER_STORAGE_DIR /storage

# we'll make these, in expectation of the user mounting something in here
RUN mkdir -p /storage/ccache
RUN mkdir -p /storage/artifacts
RUN mkdir -p /storage/downloads
RUN mkdir -p /storage/dev_packages

# Install BinaryBuilder
ADD https://api.github.com/repos/JuliaPackaging/BinaryBuilder.jl/git/refs/heads/master /usr/share/binarybuilder_version.json
RUN julia -e 'using Pkg; Pkg.add(PackageSpec(name="BinaryBuilder", rev="master"))'
RUN julia -e 'using Pkg; Pkg.API.precompile();'

# Force artifact storage into /storage/artifacts
RUN rm -rf /root/.julia/artifacts
RUN ln -fs /storage/artifacts /root/.julia/artifacts

# The user should mount something in /storage so that it persists from run to run
