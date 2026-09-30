#!/usr/bin/env bash
# Stop all running containers and quit Docker Desktop.
# Usage: ./scripts/shut-down-docker.sh

docker stop $(docker ps -q)              # Stop every running container (e.g. the one from run-local.sh)
osascript -e 'quit app "Docker"'         # Quit Docker Desktop, which also stops the Docker engine
