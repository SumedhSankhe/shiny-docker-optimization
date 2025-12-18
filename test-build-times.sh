#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Docker Build Time Comparison ===${NC}"
echo ""

# Function to time a build
time_build() {
    local dockerfile=$1
    local tag=$2
    local description=$3

    echo -e "${YELLOW}Building ${description}...${NC}"
    START=$(date +%s)
    docker build -f "$dockerfile" -t "$tag" . > /dev/null 2>&1
    END=$(date +%s)
    DURATION=$((END - START))

    # Convert to minutes and seconds
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))

    echo -e "${GREEN}✓ ${description}: ${MINUTES}m ${SECONDS}s${NC}"
    echo "$DURATION" > "/tmp/build_time_${tag//[:\/]/_}.txt"
}

# Test 1: Cold Build
echo -e "${RED}TEST 1: Cold Build (no cache)${NC}"
echo "Clearing Docker build cache..."
docker builder prune -af > /dev/null 2>&1

time_build "Dockerfile.single-stage" "shiny-app:single" "Single-stage (cold)"
time_build "Dockerfile.multistage" "shiny-app:two-stage" "Two-stage (cold)"
time_build "Dockerfile.three-stage" "shiny-app:three-stage" "Three-stage (cold)"

echo ""
echo -e "${YELLOW}Cold build complete. Now testing warm builds...${NC}"
sleep 2

# Test 2: Warm Build - Code Change Only
echo ""
echo -e "${RED}TEST 2: Warm Build - Code Change Only${NC}"
echo "Making trivial code change..."
echo "# Test comment $(date +%s)" >> app.R

time_build "Dockerfile.single-stage" "shiny-app:single" "Single-stage (warm, code change)"
time_build "Dockerfile.multistage" "shiny-app:two-stage" "Two-stage (warm, code change)"
time_build "Dockerfile.three-stage" "shiny-app:three-stage" "Three-stage (warm, code change)"

# Restore original app.R
git checkout app.R 2>/dev/null || true

echo ""
echo -e "${GREEN}=== Build Time Summary ===${NC}"
echo ""
echo "| Build Type | Single-Stage | Two-Stage | Three-Stage |"
echo "|------------|--------------|-----------|-------------|"

# Read cold build times
SINGLE_COLD=$(cat /tmp/build_time_shiny-app_single.txt)
TWO_COLD=$(cat /tmp/build_time_shiny-app_two-stage.txt)
THREE_COLD=$(cat /tmp/build_time_shiny-app_three-stage.txt)

echo -n "| Cold build | "
printf "%dm %ds | " $((SINGLE_COLD / 60)) $((SINGLE_COLD % 60))
printf "%dm %ds | " $((TWO_COLD / 60)) $((TWO_COLD % 60))
printf "%dm %ds |\n" $((THREE_COLD / 60)) $((THREE_COLD % 60))

echo -n "| Warm build | "
# Note: These are from the second build in test 2
printf "%dm %ds | " $((SINGLE_COLD / 60)) $((SINGLE_COLD % 60))
printf "%dm %ds | " $((TWO_COLD / 60)) $((TWO_COLD % 60))
printf "%dm %ds |\n" $((THREE_COLD / 60)) $((THREE_COLD % 60))

echo ""
echo -e "${YELLOW}Image Sizes:${NC}"
docker images | grep shiny-app | awk '{printf "%-20s %10s\n", $1":"$2, $7}'

# Cleanup temp files
rm -f /tmp/build_time_*.txt

echo ""
echo -e "${GREEN}Testing complete!${NC}"
