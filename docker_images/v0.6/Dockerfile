FROM julia:0.6

# Install `sudo`, which gets used by BinaryBuilder
RUN apt-get update && apt-get install -y sudo

# Set useful envvars
ENV BINARYBUILDER_USE_SQUASHFS true
ENV BINARYBUILDER_DOWNLOADS_CACHE /shards
ENV BINARYBUILDER_AUTOMATIC_APPLE true
ENV BINARYBUILDER_USE_CCACHE true

# Install BinaryBuilder
RUN julia -e 'Pkg.clone("https://github.com/JuliaPackaging/BinaryBuilder.jl.git"); using BinaryBuilder'
