---
title: "Optimizing R Shiny Docker Builds: From 40 Minutes to 10 Minutes"
date: 2024-12-16
author: Sumedh R. Sankhe
tags: [Docker, R, Shiny, DevOps, Performance, Kubernetes, SaaS]
description: "How we reduced Docker build times by 80% and image sizes by 42% for a customer-facing R Shiny SaaS application using multistage builds with rocker/r2u"
---

# Optimizing R Shiny Docker Builds: From 40 Minutes to 10 Minutes

This is my first time writing up a technical blog post, so bear with me. I'm going to share what I learned optimizing Docker builds for R Shiny apps, including all the mistakes I made along the way.

At Alamar Biosciences, I work on the NULISA Analysis Software (NAS) - basically a Shiny app for analyzing proteomics data. Unlike typical internal Shiny apps deployed with Posit Connect, NAS is a **customer-facing SaaS application** running on Azure Kubernetes Service (AKS). Our customers access it directly for analyzing their proteomics experiments, which means deployment speed, reliability, and scalability matter differently than for internal tools.

When I started, our Docker builds were painfully slow. Like, grab coffee, queue some villagers in AoE2, maybe respond to some emails slow. A simple one-line code change? Wait 40 minutes for Docker to rebuild the image. Our images were pushing 1.5GB compressed. Every deployment to Kubernetes felt like it took forever. When you're shipping features to customers and fixing production bugs, 40-minute build times kill your velocity.

This post walks through how I cut Docker build times by 80% for code changes (40 mins → 8-15 mins) and reduced image sizes by 42% (1.5GB → 875MB). The optimization involves separating build from runtime using Docker multistage builds and leveraging rocker/r2u for binary package installation. More importantly, this post covers the things that broke along the way and how I fixed them.

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
3. Wait 40 minutes (go get coffee, check Slack, lose focus)
4. Push to Azure Container Registry
5. Deploy to AKS

Those build times killed productivity. You'd push a fix, then switch to something else while waiting. By the time the build finished, you'd forgotten what you were even working on. It was like waiting for a Wonder to be built while your opponents are rushing you with trebuchets.

**Why this matters for SaaS:** With Posit Connect, you typically deploy once and iterate internally. With a customer-facing SaaS on Kubernetes, you're constantly shipping features, bug fixes, and updates. Fast build times directly impact how quickly you can respond to customer issues and ship improvements. A 40-minute build cycle means you can only deploy 2-3 times per day max. That's not acceptable for modern SaaS development.

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
| **Image size (uncompressed)** | 1.89 GB | 1.44 GB | 1.44 GB | **24% smaller** |
| **Image size (compressed/registry)** | 512 MB | 403 MB | 403 MB | **21% smaller** |
| **Warm build** (code change only) | 5-7 mins | 30-45s | 30-45s | **85-92% faster** |
| **Cold build** (no cache) | 8-10 mins | 6-8 mins | 6-8 mins | 20-25% faster |

For our production NAS application with 200+ CRAN packages and 2 custom in-house packages:

| Metric | Before (Single-Stage) | After (Three-Stage) | Improvement |
|--------|----------------------|---------------------|-------------|
| **Image size (compressed)** | 1.5 GB | 875 MB | **42% smaller** |
| **Cold build** (all layers) | 40 mins | 30-35 mins | **20-25% faster** |
| **Warm build** (code change only) | 40 mins | 8-15 mins | **70-80% faster** |

**Note:** Our production setup includes additional optimizations beyond the scope of this post: automated base image rebuilds triggered by renv.lock hash changes, cache-busting strategies for custom package updates, and GitHub Actions runner cleanup for multi-stage builds. These advanced CI/CD integrations will be covered in a follow-up post.

**Note on image sizes:** Container registries (like Azure Container Registry, Docker Hub, GitHub Container Registry) store images in compressed format, which is why the "compressed/registry" sizes are significantly smaller than what you see locally with `docker images`. When you push an image to a registry, Docker compresses the layers, typically achieving 25-35% of the uncompressed size. This is important when considering deployment times and registry storage costs.

**Note on warm builds:** Even single-stage Dockerfiles can have warm builds if you structure the layers correctly. The problem is that most single-stage setups use `COPY . .` early, which invalidates package installation on every code change. Our original single-stage Dockerfile had this issue, which is why warm builds were still slow.

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
COPY renv.lock .            # Only changes when you add/remove packages
RUN R -e "renv::restore()"  # Gets cached and reused for code changes
COPY app.R .                # Changes all the time, but doesn't break cache above
```

That simple reordering is the entire reason warm builds went from 8-10 minutes to 30 seconds. Put your stable stuff first, your frequently changing stuff last.

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

### 2. Parallel Package Installation

This is a small win but it adds up:

```dockerfile
RUN R -e "options(Ncpus = 4); renv::restore()"
```

Uses 4 cores to compile packages instead of 1. On a GitHub Actions runner, this shaved off another minute or two.

### 3. Pick the Right Base Image

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
