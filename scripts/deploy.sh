#!/usr/bin/env bash
# Deploy k8s/app.yaml to the cluster with the ECR image filled in, and wait for the rollout.
# Usage: ./scripts/deploy.sh <tag>    (e.g. ./scripts/deploy.sh v1, ./scripts/deploy.sh v2, ./scripts/deploy.sh v3)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

TAG="${1:?Usage: ./scripts/deploy.sh <tag>  (e.g. ./scripts/deploy.sh v1)}"  # Image tag from the first argument (required); stops with the usage message if missing
AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/deploy.sh
REPO="${REPO:-eks-deploy-sample}"        # ECR repository name
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)  # AWS account ID of the current credentials
IMAGE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO:$TAG"          # Full image address to deploy

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so k8s/app.yaml is found

echo "==> Deploying $IMAGE"              # Progress message
sed "s|IMAGE_URI|$IMAGE|" k8s/app.yaml | kubectl apply -f -  # Replace the IMAGE_URI placeholder and apply the manifest

echo "==> Waiting for rollout"           # Progress message
kubectl rollout status deployment/eks-deploy-sample --timeout=5m  # Block until all pods are updated and ready (fail after 5 min)

echo "==> Pods:"                         # Progress message
kubectl get pods -l app=eks-deploy-sample  # Should show 2 pods at 1/1 Running

echo "==> Service:"                      # Progress message
kubectl get svc eks-deploy-sample-svc    # EXTERNAL-IP is the load balancer hostname (may show <pending> for a minute)
