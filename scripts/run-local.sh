#!/usr/bin/env bash
# Build the jar, build the Docker image, and run the container in the foreground.
# Usage: ./scripts/run-local.sh    (Ctrl+C to stop)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

IMAGE="eks-deploy-sample:local"          # Docker image name:tag to build and run
PORT="${PORT:-8080}"                     # Host port; defaults to 8080, override with PORT=9090 ./scripts/run-local.sh

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so pom.xml and Dockerfile are found

echo "==> Building jar"                  # Progress message
mvn clean package -DskipTests            # Delete old target/ and build a fresh jar, skipping tests

echo "==> Building image $IMAGE"         # Progress message
docker build -t "$IMAGE" .               # Build the image from the Dockerfile in this folder

echo "==> Running $IMAGE on http://localhost:$PORT (Ctrl+C to stop)"  # Progress message
exec docker run --rm -it -p "$PORT:8080" "$IMAGE"  # Run in foreground; --rm removes container on exit, -it attaches terminal, -p maps host port to container 8080
