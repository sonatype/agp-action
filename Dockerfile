# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.

# AGP GitHub Action Docker Image
# Runtime image with nvm, Node 20/22 LTS, git, gh CLI, and AGP binary

FROM alpine:3.21

# AGP version to download (set during release)
ARG AGP_VERSION=latest

# Install system dependencies
# Note: bash is required for nvm, libstdc++ is required for Node.js
# gcompat provides glibc compatibility for the Bun-compiled AGP binary
RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    gcompat \
    git \
    github-cli \
    jq \
    libstdc++

# Install nvm and Node.js LTS versions
ENV NVM_DIR=/usr/local/nvm
ENV NODE_VERSION_DEFAULT=22

RUN mkdir -p $NVM_DIR \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . $NVM_DIR/nvm.sh \
    && nvm install 20 \
    && nvm install 22 \
    && nvm alias default 22 \
    && nvm cache clear

# Make nvm available in non-interactive shells
ENV PATH="$NVM_DIR/versions/node/v22.13.1/bin:$PATH"

# Copy AGP binary (included in repo by release workflow)
COPY agp-linux-x64 /usr/local/bin/agp
RUN chmod +x /usr/local/bin/agp

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create non-root user matching GitHub Actions runner
RUN adduser -D -u 1001 -s /bin/bash agp \
    && mkdir -p /github/workspace \
    && chown -R agp:agp /github

# Set working directory
WORKDIR /github/workspace

# Run as non-root user
USER agp

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
