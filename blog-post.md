---
title: "Optimizing R Shiny Docker Builds: Warm vs Cold Build Strategy"
date: 2024-12-16
author: Sumedh R. Sankhe
tags: [Docker, R, Shiny, DevOps, Performance, Kubernetes, SaaS]
description: "How we optimized Docker builds for a customer-facing R Shiny SaaS application by separating code changes (8-15 min) from dependency changes (40 min) and reduced image sizes by 42%"
---

# Optimizing R Shiny Docker Builds: Warm vs Cold Build Strategy

This is my first time writing up a technical blog post, so bear with me. I'm going to share what we learned optimizing Docker builds for R Shiny apps, including the things that broke along the way.

At Alamar Biosciences, I work on the NULISA Analysis Software (NAS) - a **large-scale, customer-facing SaaS application** for analyzing proteomics data, built with R Shiny and running on Azure Kubernetes Service (AKS). NAS is used by customers across academia and industry worldwide as a free cloud service. Unlike typical internal Shiny apps deployed with Posit Connect, NAS serves external customers directly, which means deployment speed, reliability, and scalability are critical for customer satisfaction and platform availability.

Our Docker builds were taking 20-25 minutes. Every. Single. Build. It didn't matter if you changed one line of code or overhauled the entire data processing pipeline—Docker would reinstall all 200+ R packages from scratch. A simple bug fix? Wait 25 minutes. Testing a UI tweak? Another 25 minutes. Our images were pushing 1.5GB compressed to Azure Container Registry. When you're shipping features to customers and fixing production bugs, treating every build the same kills your velocity.

This post walks through the optimizations we implemented in late 2025 that fundamentally changed how we build Docker images. The key insight: **separate code changes from dependency changes**. Now, the common case (code changes) builds in 8-15 minutes—a 60-68% improvement—while dependency updates take longer (40 mins) but happen infrequently. We also reduced image sizes by 42% (1.5GB → 870MB compressed in ACR). The optimization involves splitting stable CRAN dependencies into a base image, leveraging rocker/r2u for binary package installation, and properly structuring multistage builds. More importantly, this post covers the things that broke along the way and how we fixed them.

## The Problem: Slow, Bloated Docker Images

Our original Dockerfile followed a common pattern—straightforward but inefficient:

```dockerfile
FROM rocker/r2u:24.04

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    # ... many more -dev packages

WORKDIR /app

# Copy everything at once
COPY . .

# Install R packages
RUN R -e "install.packages('renv')"
RUN R -e "renv::restore()"

EXPOSE 3838
CMD ["R", "-e", "shiny::runApp('/app', host='0.0.0.0', port=3838)"]
```

This approach had three big problems:

### Problem 1: Poor Layer Caching

Any change to our application code—even fixing a typo in `app.R`—would invalidate the `renv::restore()` layer. Docker would reinstall ALL 200+ R packages from scratch. We're talking the usual suspects like `ggplot2`, `plotly`, `DT`, plus a ton of domain-specific proteomics packages, and 2 custom in-house packages. Every. Single. Time. On our GitHub Actions runners, that's 60+ minutes of watching packages compile and tests run.

### Problem 2: Bloated Production Images

Our final images had everything needed to build the app, not just run it. All the build tools like `gcc`, `make`, and those `-dev` system libraries were just sitting there in production taking up space. The result? Nearly 2GB uncompressed images when the actual runtime stuff could be much smaller.

### Problem 3: Slow CI/CD Pipelines

Here's what our Azure Kubernetes deployment looked like:
1. Push a code change (bug fix, new feature, etc.)
2. GitHub Actions starts building
3. Wait 20-25 minutes (go get coffee, check Slack, lose focus)
4. Push to Azure Container Registry
5. Deploy to AKS

Those build times killed productivity. You'd push a fix, then switch to something else while waiting. By the time the build finished, you'd forgotten what you were even working on. It was like waiting for a Wonder to be built while your opponents are rushing you with trebuchets.

**Why this matters for SaaS:** With Posit Connect, you typically deploy once and iterate internally. With a customer-facing SaaS on Kubernetes, you're constantly shipping features, bug fixes, and updates. Fast build times directly impact how quickly you can respond to customer issues and ship improvements. A 25-minute build cycle for every code change means you can only deploy a handful of times per day. That's not acceptable for modern SaaS development.

## The Solution: Multistage Docker Builds

The fix involves three core strategies (think of it as your build order):

1. **Separate build from runtime** using Docker multistage builds
2. **Optimize layer caching** by copying dependencies before code
3. **Minimize runtime dependencies** to only what's needed to run the app

Let me show you exactly how this works. If you're familiar with AoE2, this is basically advancing from Dark Age (single-stage mess) to Imperial Age (optimized multistage build).

## Implementation: Building the Optimized Dockerfile

I'm going to walk through the multistage Dockerfile step by step. In the demo repo, I have a simple two-stage version for the example app. But for NAS, we actually use a three-stage build that separates CRAN packages from our custom packages. This makes sense when you have custom packages that change more frequently than your CRAN dependencies. For simpler apps, two stages is plenty.

### Stage 1: The Builder

This stage compiles all the packages and prepares the app. In our real NAS setup, this is where we also install custom packages and run unit tests (unit testing in Docker builds deserves its own blog post, so I won't dive into that here):

```dockerfile
# ============ STAGE 1: Builder ============
FROM rocker/r2u:24.04 AS builder

# Configure renv cache to use consistent path across stages
ENV RENV_PATHS_CACHE="/app/renv/.cache"

# Install build dependencies (with -dev packages)
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# CRITICAL: Copy ONLY dependency files first
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json

# Install packages - this layer is cached unless renv.lock changes
RUN R -e "install.packages('renv', repos='https://cloud.r-project.org')"
RUN R -e "renv::restore()"

# Copy application code AFTER dependencies are installed
# This means code changes don't invalidate the package layer
COPY app.R app.R
```

**The key part:** Notice how we copy `renv.lock` and the renv files separately from `app.R`. Your lockfile only changes when you add or remove packages (maybe once a week?). Your application code changes constantly (multiple times a day). By separating them, Docker can cache the expensive `renv::restore()` step and skip it when you only change your app code.

### Stage 2: The Runtime

Now we build a clean runtime image that only has what's needed to run the app:

```dockerfile
# ============ STAGE 2: Runtime ============
FROM rocker/r2u:24.04

# Configure renv cache to match builder stage
ENV RENV_PATHS_CACHE="/app/renv/.cache"

# Install ONLY runtime libraries (no -dev packages)
RUN apt-get update && apt-get install -y \
    libcurl4 \
    libssl3 \
    libxml2 \
    libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the compiled renv library from builder (includes cache)
COPY --from=builder /app/renv /app/renv
COPY --from=builder /app/.Rprofile /app/.Rprofile
COPY --from=builder /app/renv.lock /app/renv.lock

# Copy application code
COPY --from=builder /app/app.R /app/app.R

EXPOSE 3838
CMD ["R", "--vanilla", "-e", ".libPaths('/app/renv/library/linux-ubuntu-noble/R-4.5/x86_64-pc-linux-gnu'); shiny::runApp('/app', host='0.0.0.0', port=3838)"]
```

**What's happening here:** The runtime stage starts fresh and uses `COPY --from=builder` to grab the compiled packages. Notice we're installing `libcurl4` instead of `libcurl4-openssl-dev`. The `-dev` packages include headers and build tools. We don't need those to run the app, only to compile packages. This alone saves hundreds of megabytes.

Also notice the CMD uses `--vanilla` - that's the fix for the renv runtime issue I mentioned earlier.

## Things That Broke (And How I Fixed Them)

Okay, so I thought I was done after writing the multistage Dockerfile. Built the images, they looked great. Then I actually tried to run them and... the app wouldn't start. Here's what went wrong.

### Issue 1: renv Trying to Reinstall Packages at Runtime

The containers would start, but then renv would activate (because of `.Rprofile`) and immediately complain that packages were missing or out of sync. It would try to reinstall everything at runtime. Turns out my `renv.lock` file was missing a bunch of transitive dependencies - things like `cpp11`, `crosstalk`, `farver`. These aren't packages I explicitly use, but they're dependencies of dependencies.

When renv detected these weren't in the lockfile, it thought something was wrong and tried to "fix" it by reinstalling. In a running container. Which obviously failed.

**The fix:** I disabled renv activation at runtime by using `R --vanilla` which skips the `.Rprofile`. Then I explicitly set the library path in the CMD:

```dockerfile
CMD ["R", "--vanilla", "-e", ".libPaths('/app/renv/library/linux-ubuntu-noble/R-4.5/x86_64-pc-linux-gnu'); shiny::runApp('/app', host = '0.0.0.0', port = 3838)"]
```

This way, R uses the pre-installed packages but doesn't trigger renv's "helpful" automatic restoration.

### Issue 2: Broken Symlinks in Multistage Builds

Even after fixing the renv activation issue, the multistage builds still wouldn't work. Shiny couldn't find any packages. Turns out renv uses symlinks to a cache directory at `/root/.cache/R/renv/cache/`. When I copied the renv library between stages, I was copying the symlinks but not the actual files they pointed to. So every package was just a broken link.

I spent way too long debugging this before I realized what was happening.

**The fix:** Copy the renv cache along with the library:

```dockerfile
# Copy the renv cache (symlinks in renv/library point to this cache)
COPY --from=builder /root/.cache/R/renv /root/.cache/R/renv
```

Now the symlinks work and packages load properly.

### Lesson Learned

Test your containers actually run, not just build. I wasted a couple hours assuming that if the build succeeded, everything was fine. Docker's multistage builds add complexity, especially with package managers that use caching strategies like renv. Don't be like me clicking "I'm ready!" before actually being ready - test your builds like you're scouting your opponent's base before committing to a strategy.

## Results: Quantified Performance Improvements

Here are the real numbers from our GitHub Actions workflow on the demo repo:

| Metric | Single-Stage | Two-Stage | Three-Stage | Improvement |
|--------|-------------|-----------|-------------|-------------|
| **Image size (GHCR)** | 1.27 GB | 948 MB | 948 MB | **25% smaller** |
| **Warm build** (code change only) | 5-7 mins | ~30s | ~30s | **92-94% faster** |
| **Cold build** (no cache) | 8-10 mins | 6-8 mins | 6-8 mins | 20-25% faster |

For our production NAS application with 200+ CRAN packages and 2 custom in-house packages:

| Metric | Before (NAS 1.3) | After (NAS 1.4) | Improvement |
|--------|------------------|-----------------|-------------|
| **Image size (ACR compressed)** | 1.5 GB | 870 MB | **42% smaller** |
| **Warm build** (code change only) | 20-25 mins | 8-15 mins | **60-68% faster** |
| **Cold build** (dependency change) | 20-25 mins | 40 mins | Slower, but infrequent |

**Note:** Our production setup includes additional optimizations beyond the scope of this post: automated base image rebuilds triggered by renv.lock hash changes, cache-busting strategies for custom package updates, and GitHub Actions runner cleanup for multi-stage builds. These advanced CI/CD integrations will be covered in a follow-up post.

**Note on image sizes:** The sizes shown are **compressed sizes** as stored in container registries (ACR/GHCR). These are the sizes that matter for:
- Registry storage costs
- Network transfer time during push/pull
- Initial deployment speed to Kubernetes

Container registries compress images to about 25-35% of their uncompressed size. So the 870MB compressed NAS image is ~2.2-2.6GB when uncompressed on disk. The demo app achieves a 25% reduction in registry size, while our production NAS app sees a 42% reduction (1.5GB → 870MB in ACR).

**Note on warm vs cold builds:** The key optimization is **distinguishing between these two scenarios**. Our original setup treated every build the same—changing one line of code triggered a full 20-25 minute rebuild with all packages reinstalled. The optimized approach separates:
- **Warm builds** (90% of builds): Code changes only → 8-15 mins
- **Cold builds** (10% of builds): Dependency changes → 40 mins (longer, but comprehensive and cached)

Yes, cold builds are now slower, but they happen rarely (when you add/update packages). The common case (shipping code) is 60-68% faster.

The full CI/CD pipeline includes additional steps beyond the Docker build: running unit tests, extracting test results, publishing them to GitHub, security scanning, etc. That's why the end-to-end time is longer than just the Docker build. The unit testing integration will be covered in a separate blog post.

## How Layer Caching Actually Works

This took me a while to really understand, so let me break it down. Each `RUN`, `COPY`, or `ADD` instruction in a Dockerfile creates a new layer. Docker caches these layers and reuses them if:

1. The instruction hasn't changed
2. All previous layers are unchanged
3. For `COPY`, the file contents are identical

**The wrong way (what I had originally):**
```dockerfile
COPY . .                    # Any file change invalidates this
RUN R -e "renv::restore()"  # So this has to run again. Every time.
```

**The right way:**
```dockerfile
COPY renv.lock .            # Only changes when you add/remove packages (COLD build)
RUN R -e "renv::restore()"  # Gets cached and reused for code changes (enables WARM builds)
COPY app.R .                # Changes all the time, but doesn't break cache above (WARM build)
```

That simple reordering creates the warm/cold build distinction:
- **Warm build**: `app.R` changes, `renv.lock` unchanged → `renv::restore()` layer is cached, build takes 30s
- **Cold build**: `renv.lock` changes → `renv::restore()` runs, takes 6-8 mins for the demo app (40 mins for NAS with 200+ packages)

Put your stable stuff first, your frequently changing stuff last.

## How This Works in Production

Here's how this fits into our actual Azure Kubernetes pipeline:

```yaml
# .github/workflows/deploy.yml (simplified)
name: Build and Deploy to AKS

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build Docker image
        run: |
          docker build \
            -f Dockerfile.multistage \
            -t nasapp:${{ github.sha }} \
            --cache-from nasapp:latest \
            .
      
      - name: Push to ACR
        run: |
          docker tag nasapp:${{ github.sha }} \
            ${{ secrets.ACR_NAME }}.azurecr.io/nasapp:${{ github.sha }}
          docker push ${{ secrets.ACR_NAME }}.azurecr.io/nasapp:${{ github.sha }}
```

The `--cache-from` flag helps Docker reuse layers from previous builds, which makes the caching even better.

## Other Things That Helped

Once I got the basic multistage build working, here are some other tricks I picked up:

### 1. BuildKit and Build Secrets

If you have private R packages (we do), you need to pass GitHub PATs or other credentials. Don't bake them into your image:

```dockerfile
# syntax=docker/dockerfile:1

RUN --mount=type=secret,id=github_pat \
    GITHUB_PAT=$(cat /run/secrets/github_pat) \
    R -e "renv::restore()"
```

This keeps secrets out of your layers.

### 2. Pick the Right Base Image

Use `rocker/r2u` for significantly faster package installation through binary packages. This is especially beneficial for large projects with many dependencies.

```dockerfile
FROM rocker/r2u:24.04 AS builder
```

If you need Shiny Server (we don't - we use Kubernetes and run Shiny directly), `rocker/shiny` is also available with Shiny Server pre-installed. However, for Kubernetes deployments, `rocker/r2u` provides faster builds with smaller images.

## What I Learned

1. **Test everything**: Building successfully doesn't mean it runs successfully
2. **Measure what matters**: I cared way more about warm rebuild time than cold build time - optimize for your actual gameplay, not theoretical perfect builds
3. **Order matters**: Put stable stuff (dependencies) before frequently changing stuff (code)
4. **renv has quirks**: It's great for reproducibility but you need to understand its caching and symlink behavior when containerizing

## Try It Yourself

I put together a working example with all the code:

**GitHub Repository**: [shiny-docker-optimization](https://github.com/SumedhSankhe/shiny-docker-optimization)

It includes:
- A simple Shiny app (mtcars dashboard, nothing fancy)
- Three Dockerfiles: single-stage (bad), multistage (better), and three-stage (for complex apps)
- Full renv setup that actually works
- Scripts to test build times

Note: This demo app is way simpler than NAS (a few packages vs 200+, no custom packages, no unit tests). But the principles are the same, and you can see the optimization benefits even on a small app.

Clone it and compare the results:

```bash
git clone https://github.com/SumedhSankhe/shiny-docker-optimization.git
cd shiny-docker-optimization

# Build both versions
docker build -f Dockerfile.single-stage -t shiny-app:single .
docker build -f Dockerfile.multistage -t shiny-app:optimized .

# Compare sizes
docker images | grep shiny-app

# Run it
docker run -p 3838:3838 shiny-app:optimized
# Open localhost:3838
```

## Wrapping Up

This was my first real dive into Docker optimization and I learned a lot. The multistage build approach is now what I use for all our Shiny apps at work. The principles apply to other languages too - separate build from runtime, order your layers carefully, and test that things actually run.

If you're deploying Shiny apps in containers, hopefully this saves you some time and headache.

---

**Found this helpful or have questions?** Open an issue on the [GitHub repo](https://github.com/SumedhSankhe/shiny-docker-optimization) or connect with me on [LinkedIn](https://linkedin.com/in/sumedhsankhe).

**Some resources I found useful:**
- [Engineering Production-Grade Shiny Apps](https://engineering-shiny.org/) - Great book on building real Shiny apps
- [Docker Build Best Practices](https://docs.docker.com/develop/dev-best-practices/) - Official Docker docs
- [renv documentation](https://rstudio.github.io/renv/) - Understanding how renv works helps a lot
