# Use Ubuntu 24.04 as a robust base image for the builder
FROM ubuntu:24.04

# Avoid tzdata interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install all dependencies required to build the Azure Linux ISOs
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        dnf \
        xorriso \
        squashfs-tools \
        dosfstools \
        mtools \
        dracut \
        qemu-user-static \
        ca-certificates \
        curl \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# Set up the workspace
WORKDIR /workspace

# The entrypoint will be the main build script
# When running the container, the repository should be mounted to /workspace
ENTRYPOINT ["/workspace/build-azl4-iso.sh"]
