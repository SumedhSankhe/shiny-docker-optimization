---
title: "Docker Optimization Part 2: Intelligent Caching for R Shiny Applications"
date: 2025-12-23
author: Sumedh R. Sankhe
tags: [Docker, R, Shiny, DevOps, CI/CD, GitHub Actions, Testing]
description: "Advanced Docker caching strategies: hash-based base images, tests as build gates, and cache busting for external packages"
---

# Docker Optimization Part 2: Intelligent Caching for R Shiny Applications

In [Part 1](docker-optimization.html), we covered the basics of multistage builds and layer caching for R Shiny applications. If you haven't read it, the TL;DR is: separate your slow-changing dependencies from fast-changing application code, and Docker's layer cache will reward you with faster builds.

But here's what I didn't tell you: that approach has a blind spot. A big one.

## The Problem Nobody Talks About

Picture this: your `renv.lock` hasn't changed in two weeks. Your Dockerfile is identical. You push a one-line bug fix. Docker sees nothing changed in the dependency layers, serves everything from cache, and your build finishes in 3 minutes. Beautiful.

Except... your teammate just pushed a critical fix to an internal R package hosted on GitHub. Your build used the cached version. The fix isn't in your image. You deploy. Production breaks.

This is the "phantom dependency" problem. Docker's layer cache is content-addressed—it only knows about files *in your repository*. It has no idea that `renv::install("org/package")` now points to different code than it did yesterday.

We needed to solve two distinct caching problems:

1. **Lock file changes**: When `renv.lock` updates, rebuild the base image
2. **External package changes**: When upstream GitHub packages change (but lock file doesn't), invalidate just that layer

And while we're at it, why not make tests a build gate? If tests fail, the image shouldn't exist.

## Solution 1: Hash-Based Base Images

The insight is simple: treat your lock file as a cache key. Same lock file = same dependencies = reuse the image. Different hash = rebuild.

Here's the mechanism:

```bash
# Compute a 12-character hash of your lock file
LOCK_HASH=$(sha256sum renv.lock | cut -c1-12)

# Tag your base image with the hash
BASE_TAG="my-app-base:${VERSION}-${LOCK_HASH}"
# Example: my-app-base:1.4-dev-a3b2c1d4e5f6
```

Now your CI workflow becomes:

```yaml
- name: Check if base image exists
  run: |
    LOCK_HASH=$(sha256sum renv.lock | cut -c1-12)
    BASE_TAG="my-app-base:${BRANCH}-${LOCK_HASH}"

    if docker pull "registry.example.com/${BASE_TAG}" 2>/dev/null; then
      echo "Base image found - using cache"
      echo "needs_build=false" >> $GITHUB_OUTPUT
    else
      echo "Base image not found - will build"
      echo "needs_build=true" >> $GITHUB_OUTPUT
    fi

- name: Build base image (if needed)
  if: steps.check.outputs.needs_build == 'true'
  run: |
    docker build -f Dockerfile.base \
      --build-arg LOCK_HASH=${LOCK_HASH} \
      -t registry.example.com/${BASE_TAG} .
    docker push registry.example.com/${BASE_TAG}
```

The base Dockerfile installs everything from your lock file:

```dockerfile
# Dockerfile.base - Stable dependency layer
FROM rocker/r2u:24.04

COPY renv.lock /app/renv.lock
COPY .Rprofile /app/.Rprofile
COPY renv/activate.R /app/renv/activate.R

WORKDIR /app

# Restore all packages from lock file
RUN R -e "renv::restore()"

# Label with hash for traceability
ARG LOCK_HASH
LABEL renv.lock.hash="${LOCK_HASH}"
```

**Why this works**: The first PR that updates `renv.lock` pays the ~15 minute base image build cost. Every subsequent PR targeting that branch (with the same lock file) gets instant cache hits. When someone updates dependencies again, only then does the base image rebuild.

In practice, we saw base image rebuilds drop from "every PR" to "2-3 times per release cycle."

## Solution 2: Cache Busting for External Packages

But what about packages not in your lock file? Maybe you have internal GitHub packages that follow branch conventions (e.g., `org/analytics-core@1.4-dev`). These update frequently, but your lock file doesn't track their commits.

Docker needs a signal that something changed. We give it one:

```dockerfile
# Main Dockerfile
ARG BASE_IMAGE
ARG CACHE_BUST=0

FROM ${BASE_IMAGE} AS builder

# This layer rebuilds when CACHE_BUST changes
RUN echo "Cache bust: ${CACHE_BUST}" && \
    R -e "renv::install('org/analytics-core@${BRANCH}')"
```

The `echo` statement is the key. Docker evaluates build args, sees that `CACHE_BUST` changed, and invalidates this layer and everything after it.

In your CI:

```yaml
build-args: |
  BASE_IMAGE=registry.example.com/${BASE_TAG}
  CACHE_BUST=${{ github.run_id }}
```

Using `github.run_id` means every build gets fresh external packages. But you can also make it smarter:

```yaml
# Only bust cache when triggered by upstream repo webhook
cache-bust: ${{ inputs.cache-bust || 'stable' }}
```

This way, normal PRs use cached packages (fast), but when an upstream repo dispatches a workflow trigger, you pass a new cache-bust value and force a fresh install.

## Solution 3: Tests as Build Gates

Here's a pattern I wish I'd adopted earlier: make your Docker build fail if tests fail. Not "build the image, then run tests in a separate job." The image literally doesn't get created unless tests pass.

```dockerfile
# Dockerfile - Multi-stage with test gate
ARG BASE_IMAGE

# Stage 1: Build and Test
FROM ${BASE_IMAGE} AS builder

COPY . /app/
WORKDIR /app

# Install branch-specific packages
RUN R -e "renv::install('org/package@${BRANCH}')"

# Run tests - build FAILS if tests fail
# JUnit reporter writes XML for CI systems to parse
RUN R -e "testthat::test_dir('tests/testthat', \
    reporter = testthat::JunitReporter\$new(file = '/tmp/test-results.xml'), \
    stop_on_failure = TRUE)"

# Verify results were generated
RUN test -f /tmp/test-results.xml || exit 1


# Stage 2: Production Runtime
FROM rocker/r2u:24.04 AS runtime

WORKDIR /app

# Copy ONLY production artifacts (no tests/)
COPY --from=builder /app/renv/ /app/renv/
COPY --from=builder /app/R/ /app/R/
COPY --from=builder /app/global.R /app/
COPY --from=builder /app/server.R /app/
COPY --from=builder /app/ui.R /app/

# Note: tests/ directory stays in builder stage - not copied to runtime
```

The key insight: `stop_on_failure = TRUE` makes `testthat::test_dir()` return a non-zero exit code when tests fail, which causes the `RUN` instruction to fail, which stops the entire build. No tests passing = no image.

**Extracting test results**: The tricky part is getting JUnit XML out of a failed build for CI reporting. You need to build just the builder stage, then copy the results out:

```yaml
- name: Extract test results
  if: always()  # Run even if build failed
  run: |
    # Build only the builder stage (continues even if tests failed)
    docker build --target builder -t temp-builder . || true

    # Create container and copy results out
    docker create --name temp temp-builder
    docker cp temp:/tmp/test-results.xml ./test-results.xml || true
    docker rm temp

- name: Upload test results
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: test-results
    path: test-results.xml
```

## Putting It All Together

Here's the flow:

```
PR Opened
    │
    ▼
┌─────────────────────────────────────┐
│ Compute renv.lock hash              │
│ Check if base image exists in ACR   │
└─────────────────────────────────────┘
    │
    ├── Cache HIT ──────────────────────┐
    │                                   │
    ▼                                   ▼
┌──────────────────┐          ┌─────────────────────────┐
│ Build base image │          │ Skip base build         │
│ (~15 min)        │          │ (0 sec)                 │
└──────────────────┘          └─────────────────────────┘
    │                                   │
    └───────────────┬───────────────────┘
                    ▼
        ┌───────────────────────┐
        │ Build app image       │
        │ • Install GH packages │
        │ • Run tests           │
        │ • Build runtime       │
        └───────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
   Tests PASS            Tests FAIL
        │                       │
        ▼                       ▼
   Push image            Build aborts
   to registry           No image created
```

## Results

| Scenario | Before | After |
|----------|--------|-------|
| PR with no dependency changes | 18-22 min | 4-6 min |
| PR with renv.lock changes | 18-22 min | 18-22 min (expected) |
| Base image cache hit rate | 0% | ~85% |
| Test failures caught pre-push | 0% | 100% |

The biggest win isn't even the time savings—it's confidence. When an image exists in the registry, you *know* it passed tests. No more "the tests ran in a separate job that we forgot to check."

## Things That Broke Along the Way

**1. Registry authentication timing**: We tried checking if the base image exists *before* logging into the container registry. Obvious in hindsight.

**2. Disk space on runners**: Building both base and app images in one job exhausted GitHub runner disk space. We added conditional cleanup—aggressive cleanup only when base image needs building.

**3. Test result extraction from failed builds**: `docker build` exits non-zero when tests fail, so the container never gets created. The fix is `--target builder` to build just that stage, ignoring the runtime stage that depends on test success.

## What's Next

This setup handles unit tests, but integration tests—especially for Shiny apps with browser interactions—are a different beast. That's Part 3: running headless Chrome in Docker for `shinytest2` without wanting to throw your laptop out the window.

---

*This is Part 2 of a series on Docker optimization for R Shiny applications. [Part 1](docker-optimization.html) covers multistage builds and layer caching fundamentals.*
