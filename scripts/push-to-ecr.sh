#!/usr/bin/env bash
# Build the jar, build a linux/amd64 image, and push it to Amazon ECR.
# Usage: ./scripts/push-to-ecr.sh <tag>    (e.g. ./scripts/push-to-ecr.sh v1, ./scripts/push-to-ecr.sh v2, ./scripts/push-to-ecr.sh v3)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

TAG="${1:?Usage: ./scripts/push-to-ecr.sh <tag>  (e.g. ./scripts/push-to-ecr.sh v1)}"  # Image tag from the first argument (required); stops with the usage message if missing
AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/push-to-ecr.sh
REPO="${REPO:-eks-deploy-sample}"        # ECR repository name
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)  # AWS account ID of the current credentials
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"                 # ECR registry host for this account and region
IMAGE="$REGISTRY/$REPO:$TAG"             # Full image address to build and push

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so pom.xml and Dockerfile are found

echo "==> Ensuring ECR repository $REPO exists"  # Progress message
aws ecr describe-repositories --repository-names "$REPO" --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$REPO" --region "$AWS_REGION" >/dev/null  # Create the repo only if it's missing

echo "==> Logging Docker in to $REGISTRY"        # Progress message
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"  # Pipe a temporary ECR password into docker login

echo "==> Building jar"                  # Progress message
mvn clean package -DskipTests            # Delete old target/ and build a fresh jar, skipping tests

echo "==> Building image $IMAGE"         # Progress message
docker build --platform linux/amd64 -t "$IMAGE" .  # Build for x86 so it runs on the EKS nodes (even from an Apple Silicon Mac)

echo "==> Pushing $IMAGE"                # Progress message
docker push "$IMAGE"                     # Upload the image to ECR

echo "==> Tags now in $REPO:"            # Progress message
aws ecr list-images --repository-name "$REPO" --region "$AWS_REGION" \
  --query 'imageIds[].imageTag' --output text  # List the tags in the repo to confirm the push
