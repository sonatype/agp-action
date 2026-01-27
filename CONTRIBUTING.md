<!--
    Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
    Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
    "Sonatype" is a trademark of Sonatype, Inc.
-->

# Contributing to AGP Action

## Repository Setup

### Initial Setup (First Time Only)

1. **Create the GitHub repository** `sonatype/agp-action` (private)

2. **Configure repository settings**:
   - Go to Settings → Actions → General
   - Under "Access", select **"Accessible from repositories in the 'sonatype' organization"**

3. **Add required secrets**:
   - `SEAWORTHY_PAT`: A GitHub Personal Access Token with read access to `sonatype/seaworthy`
     - Required for the release workflow to check out the seaworthy repo

4. **Build and add the initial AGP binary**:
   ```bash
   # Clone seaworthy
   cd /path/to/seaworthy/agentic-patches-ts

   # Build the binary
   bun install
   bun build --compile --target=bun-linux-x64 --outfile=agp-linux-x64 src/index.ts

   # Copy to agp-action repo
   cp agp-linux-x64 /path/to/agp-action/
   ```

5. **Push initial commit**:
   ```bash
   cd /path/to/agp-action
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin git@github.com:sonatype/agp-action.git
   git push -u origin main
   ```

6. **Create first release**:
   - Go to Actions → Release → Run workflow
   - Enter version `1.0.0`
   - This will create `v1.0.0` and `v1` tags

## Development Workflow

### Local Testing

1. Build a test binary:
   ```bash
   cd /path/to/seaworthy/agentic-patches-ts
   bun build --compile --target=bun-linux-x64 --outfile=../agp-action-test/agp-linux-x64 src/index.ts
   ```

2. Build the Docker image locally:
   ```bash
   cd /path/to/agp-action
   docker build -t agp-action:test .
   ```

3. Test against a sample project:
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

1. **Action metadata** (`action.yml`): Add/modify inputs and outputs
2. **Docker image** (`Dockerfile`): System dependencies and base image
3. **Entrypoint** (`entrypoint.sh`): AGP execution logic and output parsing
4. **Documentation** (`README.md`): Usage examples and troubleshooting

### Releasing

1. Ensure changes are tested locally
2. Push changes to `main`
3. Go to Actions → Release → Run workflow
4. Enter the new version number (following semver)
5. The workflow will:
   - Build the latest AGP binary from seaworthy
   - Commit the binary to the repo
   - Create version tags (`vX.Y.Z` and `vX`)
   - Create a GitHub release

### Versioning Guidelines

- **Patch** (1.0.x): Bug fixes, documentation updates
- **Minor** (1.x.0): New features, new inputs/outputs (backward compatible)
- **Major** (x.0.0): Breaking changes to inputs/outputs or behavior

## Architecture

```
agp-action/
├── action.yml          # GitHub Action metadata
├── Dockerfile          # Alpine-based image with Node.js via nvm
├── entrypoint.sh       # Orchestration script
├── agp-linux-x64       # Pre-built AGP binary (managed by release workflow)
├── README.md           # User documentation
├── CONTRIBUTING.md     # This file
└── .github/
    └── workflows/
        └── release.yml # Automated release workflow
```

### How It Works

1. User references `sonatype/agp-action@v1` in their workflow
2. GitHub Actions builds the Docker image from `Dockerfile`
3. The image contains:
   - Alpine Linux with bash, git, gh CLI
   - Node.js 20 and 22 via nvm
   - Pre-built AGP binary
4. `entrypoint.sh` runs and:
   - Sets up Node.js version
   - Configures .npmrc if provided
   - Runs AGP with provided inputs
   - Parses output and sets GitHub Action outputs

## Troubleshooting Development

### Binary doesn't work on Alpine

The AGP binary is built with Bun for glibc. Alpine uses musl libc. The Dockerfile includes `gcompat` for compatibility. If issues persist:

```bash
# Test in Alpine container
docker run -it --rm alpine:3.21 sh
apk add --no-cache gcompat libstdc++
# Copy and test the binary
```

### Release workflow fails

- Check that `SEAWORTHY_PAT` secret has read access to seaworthy repo
- Verify the seaworthy ref exists (branch, tag, or commit)
- Check Bun build output for TypeScript errors
