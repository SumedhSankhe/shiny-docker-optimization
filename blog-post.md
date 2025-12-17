---
title: "Optimizing R Shiny Docker Builds: From 15 Minutes to 30 Seconds"
date: 2024-12-16
author: Sumedh R. Sankhe
tags: [Docker, R, Shiny, DevOps, Performance, Kubernetes]
description: "How we reduced Docker build times by 94% and image sizes by 43% for production R Shiny applications using multistage builds"
---

# Optimizing R Shiny Docker Builds: From 15 Minutes to 30 Seconds

When you're deploying R Shiny applications to production on Kubernetes, Docker build efficiency becomes critical. At Alamar Biosciences, we faced a common challenge: our NULISA Analysis Software (NAS) Docker builds were slow, bloated, and frustrating to iterate on. A simple code change meant waiting 8+ minutes for a rebuild. Our images ballooned to over 2GB. And every deployment felt unnecessarily slow.

This article walks through the systematic optimization process that cut our build times by 94% and reduced image sizes by 43%—improvements that compound across dozens of daily builds and deployments.

## The Problem: Slow, Bloated Docker Images

Our original Dockerfile followed a common pattern—straightforward but inefficient:

```dockerfile
FROM rocker/r-ver:4.3.2

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

This approach had three critical problems:

### Problem 1: Poor Layer Caching

Any change to our application code—even a single line in `app.R`—invalidated the `renv::restore()` layer. Docker would reinstall *all* 50+ R packages from scratch. For a complex proteomics analysis platform with dependencies like `ggplot2`, `plotly`, `DT`, and domain-specific packages, this meant 10+ minutes of redundant package compilation.

### Problem 2: Bloated Production Images

Our final images contained everything needed to *build* the application, not just *run* it. Build tools like `gcc`, `make`, and `-dev` system libraries remained in production containers. The result? 2.1GB images when the actual runtime requirements were under 1GB.

### Problem 3: Slow CI/CD Pipelines

In our Azure Kubernetes Service deployment workflow:
1. Developer pushes code change
2. GitHub Actions triggers build
3. Wait 8-15 minutes for Docker build
4. Push to Azure Container Registry
5. Deploy to AKS

Those 8-15 minute build times became a bottleneck. Developers would push changes, then context-switch while waiting. Iteration velocity suffered.

## The Solution: Multistage Docker Builds

The fix involves three core strategies:

1. **Separate build from runtime** using Docker multistage builds
2. **Optimize layer caching** by copying dependencies before code
3. **Minimize runtime dependencies** to only what's needed to run the app

Let me show you exactly how this works.

## Implementation: Building the Optimized Dockerfile

### Stage 1: The Builder

The builder stage compiles packages and prepares the application:

```dockerfile
# ============ STAGE 1: Builder ============
FROM rocker/r-ver:4.3.2 AS builder

# Install build dependencies (with -dev packages)
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

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

**Key insight**: By separating `renv.lock` from `app.R` in the COPY operations, we ensure package installation is cached independently. Your `renv.lock` file changes rarely (only when adding/removing packages), but your application code changes constantly.

### Stage 2: The Runtime

The runtime stage creates a minimal production image:

```dockerfile
# ============ STAGE 2: Runtime ============
FROM rocker/r-ver:4.3.2

# Install ONLY runtime libraries (no -dev packages)
RUN apt-get update && apt-get install -y \
    libcurl4 \
    libssl3 \
    libxml2 \
    libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the compiled renv library from builder
COPY --from=builder /build/renv /app/renv
COPY --from=builder /build/.Rprofile /app/.Rprofile
COPY --from=builder /build/renv.lock /app/renv.lock

# Copy application code
COPY --from=builder /build/app.R /app/app.R

EXPOSE 3838
CMD ["R", "-e", "shiny::runApp('/app', host='0.0.0.0', port=3838)"]
```

**Key insight**: The runtime stage uses `COPY --from=builder` to pull pre-compiled packages. It installs only the *runtime* versions of system libraries (e.g., `libcurl4` instead of `libcurl4-openssl-dev`). No build tools, no compilers, no development headers—just what's needed to execute.

## Results: Quantified Performance Improvements

Testing on NAS with 50+ R package dependencies:

| Metric | Before (Single-Stage) | After (Multistage) | Improvement |
|--------|----------------------|-------------------|-------------|
| **Cold build** (no cache) | 15m 22s | 12m 18s | 20% faster |
| **Warm build** (cached deps, code change) | 7m 45s | 28s | **94% faster** |
| **Final image size** | 2.14 GB | 1.22 GB | **43% smaller** |
| **Deployment time to AKS** | ~2m 30s | ~1m 20s | 47% faster |

The 94% improvement in warm builds is transformative for developer experience. What was a coffee-break wait is now nearly instantaneous.

## Layer Caching Deep Dive

Understanding Docker's layer caching is crucial. Each `RUN`, `COPY`, or `ADD` instruction creates a new layer. Docker caches layers and reuses them if:

1. The instruction hasn't changed
2. All previous layers are unchanged
3. For `COPY`, the file contents are identical

**Inefficient ordering:**
```dockerfile
COPY . .                    # Any file change invalidates this
RUN R -e "renv::restore()"  # This gets invalidated too!
```

**Optimized ordering:**
```dockerfile
COPY renv.lock .            # Only changes when dependencies change
RUN R -e "renv::restore()"  # Cached for code-only changes
COPY app.R .                # Frequently changes, but doesn't invalidate above
```

This strategic ordering is why our warm builds dropped from 7+ minutes to under 30 seconds.

## Production Deployment Workflow

Here's how this integrates with our Azure Kubernetes pipeline:

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

The `--cache-from` flag leverages the previous build's layers, compounding the caching benefits.

## Beyond the Basics: Advanced Optimizations

Once you've implemented multistage builds, consider these additional optimizations:

### 1. BuildKit and Build Secrets

For private package repositories:

```dockerfile
# syntax=docker/dockerfile:1

RUN --mount=type=secret,id=github_pat \
    GITHUB_PAT=$(cat /run/secrets/github_pat) \
    R -e "renv::restore()"
```

This avoids baking credentials into layers.

### 2. Parallel Package Installation

For packages with many dependencies:

```dockerfile
RUN R -e "options(Ncpus = 4); renv::restore()"
```

### 3. Base Image Selection

For Shiny apps with built-in Shiny Server:

```dockerfile
FROM rocker/shiny:4.3.2 AS builder
```

This includes pre-configured Shiny Server, reducing setup time.

## Lessons Learned

1. **Profile before optimizing**: Use `docker history` to see where size bloat comes from
2. **Measure real workflows**: Cold build time matters less than warm rebuild time
3. **Layer ordering is critical**: Most frequently changing files should be COPYed last
4. **Multistage builds compound benefits**: Faster builds + smaller images + cleaner deployments

## Try It Yourself

I've created a complete working example demonstrating these techniques:

**GitHub Repository**: [shiny-docker-optimization](https://github.com/SumedhSankhe/shiny-docker-optimization)

The repo includes:
- Example Shiny application (proteomics QC dashboard)
- Both single-stage and multistage Dockerfiles
- Complete renv setup
- Detailed README with build instructions

Clone it, build both versions, and compare the results yourself:

```bash
git clone https://github.com/SumedhSankhe/shiny-docker-optimization.git
cd shiny-docker-optimization

# Build and compare
docker build -f Dockerfile.single-stage -t shiny-app:single .
docker build -f Dockerfile.multistage -t shiny-app:optimized .
docker images | grep shiny-app
```

## Conclusion

Optimizing Docker builds for R Shiny applications isn't just about faster builds—it's about better developer experience, more efficient CI/CD pipelines, and leaner production deployments. The multistage approach demonstrated here has become standard practice for all our Shiny applications at Alamar Biosciences.

The key principles apply beyond R and Shiny: separate build from runtime, optimize layer caching through strategic ordering, and ruthlessly minimize what makes it into production images.

If you're deploying Shiny apps to Kubernetes or any containerized environment, these optimizations will pay dividends immediately.

---

**Questions or improvements?** Open an issue on the [GitHub repo](https://github.com/SumedhSankhe/shiny-docker-optimization) or connect with me on [LinkedIn](https://linkedin.com/in/sumedhsankhe).

**Related Reading**:
- [Engineering Production-Grade Shiny Apps](https://engineering-shiny.org/)
- [Docker Build Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [renv: R Dependency Management](https://rstudio.github.io/renv/)
