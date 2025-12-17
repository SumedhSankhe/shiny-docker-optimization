# Optimizing R Shiny Docker Builds: A Multistage Approach

[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white)](https://www.docker.com/)
[![R](https://img.shields.io/badge/r-%23276DC3.svg?style=flat&logo=r&logoColor=white)](https://www.r-project.org/)
[![Shiny](https://img.shields.io/badge/Shiny-shinyapps.io-blue?style=flat&logo=RStudio&logoColor=white)](https://shiny.rstudio.com/)

A practical demonstration of Docker optimization techniques for R Shiny applications, showing how multistage builds can reduce image size by 40-50% and improve build times through better layer caching.

## The Problem

When deploying production R Shiny applications, standard single-stage Dockerfiles often result in:

- **Large image sizes** (2GB+) due to build tools remaining in the final image
- **Slow build times** (15+ minutes) with poor caching efficiency
- **Frequent rebuilds** when application code changes invalidate dependency layers
- **Bloated deployments** with unnecessary build dependencies in production

## The Solution

This repository demonstrates a **multistage Docker build approach** that:

1. **Separates build and runtime stages** - build tools stay in builder, never reach production
2. **Optimizes layer caching** - dependencies cached independently from application code
3. **Reduces image size** - final images contain only runtime requirements
4. **Speeds up CI/CD** - cached layers prevent redundant package installations

## Quick Start

### Prerequisites

- Docker installed ([Get Docker](https://docs.docker.com/get-docker/))
- Basic understanding of R and Shiny

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/shiny-docker-optimization.git
cd shiny-docker-optimization

# Build single-stage version (BEFORE)
docker build -f Dockerfile.single-stage -t shiny-app:single .

# Build multistage version (AFTER)
docker build -f Dockerfile.multistage -t shiny-app:optimized .

# Compare image sizes
docker images | grep shiny-app
```

### Run the Application

```bash
# Run the optimized version
docker run -p 3838:3838 shiny-app:optimized

# Access at http://localhost:3838
```

## Performance Comparison

| Metric | Single-Stage | Multistage | Improvement |
|--------|-------------|------------|-------------|
| **Image Size** | ~2.1 GB | ~1.2 GB | **43% smaller** |
| **Build Time (cold)** | ~15 min | ~12 min | **20% faster** |
| **Build Time (cached)** | ~8 min | ~30 sec | **94% faster** |
| **Layers** | 12 | 8 (runtime) | **Cleaner** |

*Results may vary based on dependencies and hardware*

## Architecture Deep Dive

### Single-Stage Build (Before)

```dockerfile
FROM rocker/r-ver:4.3.2

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    # ... build tools remain in image

# Copy everything at once (poor caching)
COPY . .

# Install packages (invalidated by any code change)
RUN R -e "renv::restore()"
```

**Problems:**
- Build dependencies bloat final image
- Code changes invalidate package installation layer
- No separation between build and runtime requirements

### Multistage Build (After)

```dockerfile
# ============ STAGE 1: Builder ============
FROM rocker/r-ver:4.3.2 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y ...

# Copy ONLY dependency files first (cached layer)
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R

# Install packages (cached unless renv.lock changes)
RUN R -e "renv::restore()"

# Copy code AFTER dependencies
COPY app.R app.R

# ============ STAGE 2: Runtime ============
FROM rocker/r-ver:4.3.2

# Install ONLY runtime dependencies
RUN apt-get update && apt-get install -y \
    libcurl4 \    # Note: no -dev packages
    libssl3 \
    ...

# Copy from builder
COPY --from=builder /build/renv /app/renv
COPY --from=builder /build/app.R /app/app.R
```

**Improvements:**
1. Build tools excluded from final image
2. Dependencies cached independently from code
3. Minimal runtime image with only necessary libraries
4. Faster rebuilds when code changes

## Key Optimization Strategies

### 1. Layer Ordering

```dockerfile
# BAD: Code changes invalidate package installation
COPY . .
RUN R -e "renv::restore()"

# GOOD: Packages cached unless dependencies change
COPY renv.lock renv.lock
RUN R -e "renv::restore()"
COPY app.R app.R
```

### 2. Minimal Runtime Dependencies

```dockerfile
# Builder stage: -dev packages for compilation
libcurl4-openssl-dev
libssl-dev
libxml2-dev

# Runtime stage: only runtime libraries
libcurl4
libssl3
libxml2
```

### 3. Strategic COPY Operations

```dockerfile
# Copy dependency files first (changes infrequently)
COPY renv.lock .
COPY renv/activate.R renv/

# Copy code last (changes frequently)
COPY app.R .
```

## Repository Structure

```
shiny-docker-optimization/
├── app.R                      # Example Shiny application
├── Dockerfile.single-stage    # Before: Single-stage build
├── Dockerfile.multistage      # After: Optimized multistage build
├── renv.lock                  # R package dependencies
├── .Rprofile                  # renv activation
├── renv/
│   ├── activate.R             # renv bootstrap script
│   └── settings.json          # renv configuration
└── README.md                  # This file
```

## Customization Guide

### Adapting for Your Application

1. **Update dependencies** in `renv.lock`:
   ```bash
   # In your R project
   renv::snapshot()
   ```

2. **Modify system dependencies** in Dockerfiles based on your R packages:
   ```dockerfile
   # Example: Add PostgreSQL client for RPostgres package
   RUN apt-get install -y libpq-dev  # Builder
   RUN apt-get install -y libpq5     # Runtime
   ```

3. **Adjust base image** if needed:
   ```dockerfile
   # Use specific R version
   FROM rocker/r-ver:4.3.1 AS builder
   
   # Or use rocker/shiny for built-in Shiny Server
   FROM rocker/shiny:4.3.2 AS builder
   ```

### Production Considerations

- **Health checks**: Add Docker health checks for production
- **Non-root user**: Run Shiny as non-root user for security
- **Environment variables**: Use ENV for configuration
- **Secrets management**: Never hardcode credentials

## Related Resources

- [Docker Multistage Builds Documentation](https://docs.docker.com/build/building/multi-stage/)
- [renv: R Dependency Management](https://rstudio.github.io/renv/)
- [Rocker Project: Docker Images for R](https://rocker-project.org/)
- [Production-Grade Shiny Apps](https://engineering-shiny.org/)

## Contributing

Contributions welcome! Feel free to:

- Open issues for bugs or suggestions
- Submit PRs for improvements
- Share your optimization results

## License

MIT License - see LICENSE file for details

## 👤 Author

**Sumedh R. Sankhe**
- Portfolio: [sumedhsankhe.github.io](https://sumedhsankhe.github.io)
- LinkedIn: [linkedin.com/in/sumedhsankhe](https://linkedin.com/in/sumedhsankhe)
- GitHub: [@SumedhSankhe](https://github.com/SumedhSankhe)

---

⭐ If you found this helpful, consider starring the repository!

Built with practical experience from deploying production R Shiny applications on Azure Kubernetes Service.
