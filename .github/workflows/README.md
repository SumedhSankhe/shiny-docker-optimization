# GitHub Actions Workflow Setup

This directory contains GitHub Actions workflows for automated Docker image building and publishing.

## Workflow: `docker-build-push.yml`

Automatically builds all three Dockerfile variants and pushes them to GitHub Container Registry (GHCR).

### Prerequisites

1. **Enable GitHub Actions**: Should be enabled by default for most repositories
2. **Enable GitHub Container Registry**: Automatically available for public repositories
3. **Set Repository Permissions** (for private repos):
   - Go to Settings → Actions → General
   - Under "Workflow permissions", ensure "Read and write permissions" is selected

### First-Time Setup

No additional configuration needed! The workflow uses `GITHUB_TOKEN` which is automatically provided by GitHub Actions.

#### For Private Repositories

If your repository is private, you may need to:

1. Go to your repository Settings → Packages
2. Under "Package settings", ensure the package visibility is set appropriately
3. Add collaborators if needed

### How It Works

The workflow triggers on:

- **Push to `main` or `develop` branches**: Builds and pushes all three variants
- **Creating a tag** (e.g., `v1.0.0`): Builds and pushes with version tags
- **Pull requests to `main`**: Builds images but doesn't push (validation only)
- **Manual trigger**: Can run manually from Actions tab

### Image Naming Convention

Images are pushed to: `ghcr.io/<owner>/<repo>:<tag>`

For example:
- `ghcr.io/sumedhsankhe/shiny-docker-optimization:three-stage-latest`
- `ghcr.io/sumedhsankhe/shiny-docker-optimization:v1.0.0-three-stage`
- `ghcr.io/sumedhsankhe/shiny-docker-optimization:main-two-stage`

### Tags Created

Each build creates multiple tags:

| Tag Pattern | Example | Description |
|-------------|---------|-------------|
| `{variant}-latest` | `three-stage-latest` | Latest build from main branch |
| `{branch}-{variant}` | `main-three-stage` | Latest build from specific branch |
| `{variant}-sha-{hash}` | `three-stage-sha-abc1234` | Specific commit |
| `v{version}-{variant}` | `v1.0.0-three-stage` | Semantic version (on tag) |

### Matrix Strategy

The workflow builds all three variants **independently and in parallel**:

1. **single-stage** (`Dockerfile.single-stage`)
2. **two-stage** (`Dockerfile.multistage`)
3. **three-stage** (`Dockerfile.three-stage`)

**Important**: The builds run independently with `fail-fast: false`, meaning:
- If one variant fails to build, the other variants continue building
- Each successful build pushes to GHCR independently
- The image size comparison only runs if ALL THREE builds succeed
- This provides better visibility into which specific variants have issues

### Build Caching

GitHub Actions caching is enabled to speed up builds:

- **Type**: GitHub Actions cache (GHA)
- **Mode**: Max (caches all layers)
- **Result**: Subsequent builds only rebuild changed layers

Expected build times:
- First build (cold cache): 12-15 minutes
- Code change only: ~30 seconds
- Dependency change: 8-10 minutes

### Pulling Images

After a successful workflow run, pull images with:

```bash
# Login (required for private repos only)
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# Pull latest three-stage image (recommended)
docker pull ghcr.io/<owner>/<repo>:three-stage-latest

# Pull specific version
docker pull ghcr.io/<owner>/<repo>:v1.0.0-three-stage

# Run the image
docker run -p 3838:3838 ghcr.io/<owner>/<repo>:three-stage-latest
```

Replace `<owner>/<repo>` with your GitHub username and repository name.

### Creating a Release

To trigger a versioned build:

```bash
# Tag your commit
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0
```

This will create images tagged as:
- `v1.0.0-single-stage`
- `v1.0.0-two-stage`
- `v1.0.0-three-stage`
- `1.0-single-stage` (major.minor)
- `1.0-two-stage`
- `1.0-three-stage`

### Monitoring Workflow Runs

1. Go to the **Actions** tab in your GitHub repository
2. Click on "Build and Push Docker Images" workflow
3. View individual workflow runs:
   - Build logs for each variant
   - Image size comparison
   - Created tags
   - Pull commands

### Troubleshooting

#### Workflow fails with "permission denied"

**Solution**: Check repository settings:
1. Settings → Actions → General
2. Workflow permissions → "Read and write permissions"
3. Save changes

#### Cannot pull image

**For private repos**:
```bash
# Create a Personal Access Token (PAT) with read:packages scope
# Then login:
echo $PAT | docker login ghcr.io -u USERNAME --password-stdin
```

**For public repos**: No authentication needed, images are publicly accessible

#### Build is slow

- First build will always be slow (12-15 min) as cache is built
- Subsequent builds should be much faster (~30s for code changes)
- Check Actions → Cache to see cached artifacts

### Customization

To modify the workflow:

1. Edit `.github/workflows/docker-build-push.yml`
2. Common modifications:
   - Add/remove trigger branches
   - Change image registry (e.g., Docker Hub instead of GHCR)
   - Modify tagging strategy
   - Add additional build platforms
   - Add security scanning

### Best Practices

1. **Use three-stage variant** for production (best caching, smallest runtime image)
2. **Tag releases** with semantic versioning (v1.0.0, v1.1.0, etc.)
3. **Monitor build times** to ensure caching is working effectively
4. **Review image sizes** in the workflow summary after each build
5. **Pull specific versions** in production rather than `-latest` tags

### Security

- Workflow uses `GITHUB_TOKEN` which is scoped to the repository
- Images can be:
  - Public (anyone can pull)
  - Private (requires authentication)
- Set package visibility in Settings → Packages
- Consider adding vulnerability scanning (Trivy, Snyk) for production use
