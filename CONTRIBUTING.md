<!--
    Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
    Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
    "Sonatype" is a trademark of Sonatype, Inc.
-->

# Contributing to AGP Action

## Overview

The AGP GitHub Action is a **Composite Action** that uses a pre-built Docker image containing the AGP CLI. This follows the Sonatype pattern (similar to `sonatype/actions`) and provides better performance than building the image on every run.

The action pulls the public Docker Hub image `sonatype/agp:latest` (default, no auth required). A different image can be supplied via the `docker-image` input.

## Repository Structure

```
agp-action/
├── .github/
│   └── workflows/
│       ├── release.yml     # Creates version tags and GitHub releases
│       └── test.yml        # Validates action files on PR
├── .gitignore
├── action.yml              # GitHub Action metadata
├── CONTRIBUTING.md         # This file
├── Dockerfile              # Alpine image that installs @sonatype/agp from npm
├── entrypoint.sh           # Orchestration script
└── README.md               # User documentation
```

## How It Works

1. User references `sonatype/agp-action@v1` in their workflow
2. GitHub Actions runs composite action steps:
   - Pulls pre-built Docker image (`sonatype/agp:latest` by default, or `docker-image`)
   - Runs Docker container with AGP CLI
3. The Docker image contains:
   - Alpine Linux with bash, git, gh CLI
   - Node.js 22 (from Node base image)
   - AGP CLI binary (compiled with Bun)
4. `entrypoint.sh` (inside container) runs and:
   - Sets up Node.js version
   - Configures .npmrc if provided
   - Runs AGP with provided inputs
   - Parses output and sets GitHub Action outputs

## Development Workflow

### Prerequisites

- Access to `sonatype/seaworthy` repository (AGP CLI source)
- Access to Sonatype's npm registry

### Local Testing

1. Build and publish a test version of `@sonatype/agp` to the npm registry

2. Update the Dockerfile to use your test version:
   ```dockerfile
   ARG AGP_VERSION=1.0.0-test
   ```

3. Build the Docker image:
   ```bash
   docker build -t agp-action:test .
   ```

4. Test against a sample project:
   ```bash
   docker run --rm \
     -v /path/to/test-project:/github/workspace \
     -e ANTHROPIC_API_KEY=your-key \
     -e AGP_API_TOKEN=your-token \
     -e INPUT_DRY_RUN=true \
     -e INPUT_VERBOSE=true \
     agp-action:test
   ```

### Making Changes

- **Action inputs/outputs** (`action.yml`): Add or modify inputs and outputs
- **Docker image** (`Dockerfile`): System dependencies and npm installation
- **Entrypoint** (`entrypoint.sh`): AGP execution logic and output parsing
- **Documentation** (`README.md`): Usage examples and troubleshooting

## Release Process

### Prerequisites

Before releasing a new version of the action:

1. **Publish `@sonatype/agp`** to the npm registry with the same version number
2. Verify the package is accessible from the registry

### Creating a Release

1. Go to Actions → Release → Run workflow
2. Enter the version number (must match the published npm package version)
3. The workflow will:
   - Update the Dockerfile's default `AGP_VERSION`
   - Create version tags (`vX.Y.Z` and `vX`)
   - Create a GitHub release

### Versioning Guidelines

- **Patch** (1.0.x): Bug fixes, documentation updates
- **Minor** (1.x.0): New features, new inputs/outputs (backward compatible)
- **Major** (x.0.0): Breaking changes to inputs/outputs or behavior

Keep the action version in sync with the `@sonatype/agp` npm package version.

## Publishing @sonatype/agp to npm

The AGP CLI is published from the `seaworthy` repository. To publish a new version:

1. Update version in `agentic-patches-ts/package.json`
2. Build the binaries:
   ```bash
   cd agentic-patches-ts
   bun run build:all
   ```
3. Publish to npm registry:
   ```bash
   npm publish --registry https://repo.sonatype.com/repository/npm-internal/
   ```

For detailed instructions, see the seaworthy repository's documentation.

## Troubleshooting

### Docker build fails to install @sonatype/agp

- Verify the package version exists in the npm registry
- Check if the registry URL in the Dockerfile is correct
- Ensure no authentication is required for the registry (or add credentials)

### Binary doesn't work on Alpine

The AGP binary is compiled with Bun for glibc. Alpine uses musl libc. The Dockerfile includes `gcompat` for compatibility. If issues persist:

```bash
# Test in Alpine container
docker run -it --rm alpine:3.21 sh
apk add --no-cache gcompat libstdc++ nodejs npm
npm install -g @sonatype/agp
agp --help
```

### Action not accessible from other repos

Ensure the repository settings allow access:
- Settings → Actions → General → Access
- Select "Accessible from repositories in the 'sonatype' organization"
