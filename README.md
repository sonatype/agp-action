<!--
    Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
    Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
    "Sonatype" is a trademark of Sonatype, Inc.
-->

# AGP GitHub Action

AI-powered dependency upgrades for npm projects using the Agentic Patches (AGP) CLI.

## Quick Start

```yaml
name: Dependency Upgrades
on:
  schedule:
    - cron: '0 9 * * 1'  # Every Monday at 9am
  workflow_dispatch:

jobs:
  upgrade:
    runs-on: ubuntu-latest
    permissions:
      contents: write       # Required to push branches
      pull-requests: write  # Required to create PRs
    steps:
      - uses: actions/checkout@v4

      - name: Run AGP
        uses: sonatype/agp-action@v1
        with:
          create-pr: true
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Docker Image Registry

This action uses a **pre-built Docker image** instead of building from Dockerfile on every run. This significantly improves performance.

### Default: Public Registry (GitHub Container Registry)

By default, the action pulls from `ghcr.io/sonatype/agp:latest` (public, no authentication required):

```yaml
- uses: sonatype/agp-action@v1
  with:
    create-pr: true
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Option: Private Sonatype Registry (Internal Use)

For Sonatype internal users, you can use the private registry for potentially faster pulls:

```yaml
- uses: sonatype/agp-action@v1
  with:
    create-pr: true
    docker-registry: docker-all.repo.sonatype.com
    docker-username: ${{ secrets.DOCKER_USERNAME }}
    docker-password: ${{ secrets.DOCKER_PASSWORD }}
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `mode` | No | `full` | Run mode: `full` (all updates) or `security` (only vulnerable packages) |
| `vulnerabilities` | No | | JSON array of vulnerabilities to fix (for security mode, provided via workflow_dispatch) |
| `working-directory` | No | `.` | Directory containing package.json |
| `node-version` | No | `22` | Node.js version (20 or 22) |
| `create-pr` | No | `false` | Create GitHub PRs for upgrades |
| `draft-pr` | No | `false` | Create PRs as drafts |
| `enable-agent` | No | `true` | Enable AI agent for fixing validation failures |
| `max-fix-attempts` | No | `3` | Maximum AI fix attempts per group |
| `dry-run` | No | `false` | Preview changes without applying them |
| `group` | No | | Apply only a specific group by ID |
| `validation-commands` | No | | Commands to validate upgrades (newline-separated) |
| `npmrc-content` | No | | Base64-encoded .npmrc content (with tokens included) |
| `anthropic-base-url` | No | | Custom Anthropic API endpoint |
| `docker-registry` | No | `ghcr.io` | Docker registry to pull AGP image from |
| `docker-username` | No | | Docker registry username (for private registries only) |
| `docker-password` | No | | Docker registry password (for private registries only) |
| `verbose` | No | `false` | Enable verbose output |
| `git-user-name` | No | `AGP Bot` | Git user name for commits |
| `git-user-email` | No | `agp-bot@sonatype.com` | Git user email for commits |

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | API key for Claude AI (required for AI-powered fixes) |
| `AGP_API_TOKEN` | Yes | Token for AGP run tracking |
| `GITHUB_TOKEN` | Yes | GitHub token for PR creation (auto-provided by GitHub) |

## Repository Setup

Before using this action, configure your repository to allow GitHub Actions to create pull requests:

1. Go to **Repository Settings** → **Actions** → **General**
2. Scroll to **Workflow permissions**
3. Enable: ☑️ **"Allow GitHub Actions to create and approve pull requests"**
4. Click **Save**

Additionally, ensure the following labels exist in your repository (the action will use them to tag PRs):
- `dependencies` - For dependency update PRs
- `automated` - For automated changes

You can create these labels manually or they will be created automatically when AGP runs.

## Outputs

| Output | Description |
|--------|-------------|
| `run-id` | AGP run tracking ID |
| `groups-upgraded` | Number of groups successfully upgraded |
| `groups-failed` | Number of groups that failed |
| `pr-urls` | JSON array of created PR URLs |

## Versioning

This action follows semantic versioning:

```yaml
# Recommended: Use major version tag for compatible updates
uses: sonatype/agp-action@v1

# Pin to exact version
uses: sonatype/agp-action@v1.0.0

# Latest (not recommended for production)
uses: sonatype/agp-action@main
```

## Usage Examples

### Security Mode (Vulnerability Fixes Only)

Security mode is designed to be triggered by **Sonatype Guide** when vulnerabilities are discovered. Guide dispatches the workflow with vulnerability data, and AGP fixes only those specific packages.

**Workflow setup for Guide integration:**

```yaml
name: AGP Security Fixes
on:
  workflow_dispatch:
    inputs:
      mode:
        description: 'Run mode'
        required: false
        default: 'full'
      vulnerabilities:
        description: 'JSON array of vulnerabilities (provided by Guide)'
        required: false

jobs:
  security-fixes:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - name: Fix Security Vulnerabilities
        uses: sonatype/agp-action@v1
        with:
          mode: ${{ github.event.inputs.mode }}
          vulnerabilities: ${{ github.event.inputs.vulnerabilities }}
          create-pr: true
          validation-commands: |
            npm run build
            npm test
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**What happens in security mode:**
1. Sonatype Guide detects a vulnerability affecting your project
2. Guide triggers the workflow via GitHub API with vulnerability data
3. AGP filters recommendations to only affected packages
4. Creates PRs with security context (CVE IDs, severity, etc.)

**Vulnerability data format:**
```json
[
  {
    "name": "lodash",
    "severity": "high",
    "cveId": "CVE-2021-23337",
    "ghsaId": "GHSA-35jh-r3h4-6jhm",
    "summary": "Prototype pollution in lodash"
  }
]
```

### Basic Usage with PR Creation

```yaml
- name: Run AGP
  uses: sonatype/agp-action@v1
  with:
    create-pr: true
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Dry Run (Preview Only)

```yaml
- name: Preview Upgrades
  uses: sonatype/agp-action@v1
  with:
    dry-run: true
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
```

### With Custom Validation Commands

```yaml
- name: Run AGP with Validation
  uses: sonatype/agp-action@v1
  with:
    create-pr: true
    validation-commands: |
      npm run build
      npm test
      npm run lint
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### With Node.js 20

```yaml
- name: Run AGP
  uses: sonatype/agp-action@v1
  with:
    create-pr: true
    node-version: '20'
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Custom Git Configuration

Customize the Git author for commits and PRs:

```yaml
- name: Run AGP
  uses: sonatype/agp-action@v1
  with:
    create-pr: true
    git-user-name: "MyCompany Bot"
    git-user-email: "bot@mycompany.com"
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Using Outputs

```yaml
- name: Run AGP
  id: agp
  uses: sonatype/agp-action@v1
  with:
    create-pr: true
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

- name: Report Results
  run: |
    echo "Run ID: ${{ steps.agp.outputs.run-id }}"
    echo "Groups upgraded: ${{ steps.agp.outputs.groups-upgraded }}"
    echo "Groups failed: ${{ steps.agp.outputs.groups-failed }}"
    echo "PR URLs: ${{ steps.agp.outputs.pr-urls }}"
```

## Enterprise Features

### Private NPM Registry

For projects using a private npm registry (like Nexus or Artifactory), provide your `.npmrc` content with the authentication token already included:

1. Create your `.npmrc` file with the token:
   ```ini
   registry=https://nexus.company.com/repository/npm-group/
   //nexus.company.com/repository/npm-group/:_authToken=YOUR_TOKEN_HERE
   ```

2. Base64 encode it:
   ```bash
   base64 -w0 < .npmrc
   ```

3. Store as a GitHub secret (`NPMRC_BASE64`)

4. Use in your workflow:
   ```yaml
   - name: Run AGP
     uses: sonatype/agp-action@v1
     with:
       create-pr: true
       npmrc-content: ${{ secrets.NPMRC_BASE64 }}
     env:
       ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
       AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
       GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
   ```

### Proxy Support

For environments behind a corporate proxy, pass the proxy environment variables:

```yaml
- name: Run AGP
  uses: sonatype/agp-action@v1
  with:
    create-pr: true
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    HTTP_PROXY: http://proxy.company.com:8080
    HTTPS_PROXY: http://proxy.company.com:8080
    NO_PROXY: localhost,127.0.0.1,.company.com
```

### Custom Anthropic Endpoint

For VPC deployments or Anthropic API proxies:

```yaml
- name: Run AGP
  uses: sonatype/agp-action@v1
  with:
    create-pr: true
    anthropic-base-url: https://anthropic-proxy.company.com
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Monorepo Support

For monorepos, specify the working directory:

```yaml
- name: Run AGP on packages/frontend
  uses: sonatype/agp-action@v1
  with:
    working-directory: packages/frontend
    create-pr: true
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    AGP_API_TOKEN: ${{ secrets.AGP_API_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Configuration File

AGP looks for an `agp.yml` configuration file in your project. If found, it will be used instead of inline `validation-commands`:

```yaml
# agp.yml
version: "1"
validation:
  enabled: true
  commands:
    - npm run build
    - npm test
agent:
  enabled: true
  maxFixAttempts: 3
pr:
  labels:
    - dependencies
    - automated
```

## Troubleshooting

### Authentication Errors

**Problem:** "ANTHROPIC_API_KEY not set" or API authentication fails

**Solution:** Ensure you've added the `ANTHROPIC_API_KEY` secret to your repository:
1. Go to Repository Settings > Secrets and variables > Actions
2. Add `ANTHROPIC_API_KEY` with your Anthropic API key

### PR Creation Fails

**Problem:** PRs are not being created, or you see: "GitHub Actions is not permitted to create or approve pull requests"

**Solutions:**
1. **Enable GitHub Actions to create PRs** (most common issue):
   - Go to Repository Settings → Actions → General
   - Under "Workflow permissions", enable: ☑️ "Allow GitHub Actions to create and approve pull requests"
   - Click Save

2. **Add required permissions to workflow**:
   ```yaml
   permissions:
     contents: write
     pull-requests: write
   ```

3. **Ensure labels exist**:
   - Create `dependencies` and `automated` labels in your repository
   - Or let AGP create them automatically on first run

### Private Registry Authentication

**Problem:** npm install fails with 401 or 403 errors

**Solutions:**
- Verify your `.npmrc` content is correctly base64 encoded
- Ensure the token in your `.npmrc` is valid and not expired
- Check that the registry URL is correct (with or without trailing slash)

### Node.js Version Issues

**Problem:** Build fails due to Node.js compatibility

**Solution:** Try a different Node.js version:
```yaml
with:
  node-version: '20'  # or '22'
```

### Verbose Logging

For debugging, enable verbose output:
```yaml
with:
  verbose: true
```

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development instructions.

## License

Copyright (c) Sonatype, Inc. All rights reserved.
