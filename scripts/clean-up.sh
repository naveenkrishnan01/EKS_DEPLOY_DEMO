#!/usr/bin/env bash
# Delete the app, the load balancer, and the EKS cluster, then check nothing is left billing.
# Usage: ./scripts/clean-up.sh
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/clean-up.sh
CLUSTER="${CLUSTER:-eks-sample-cluster}" # EKS cluster name
REPO="${REPO:-eks-deploy-sample}"        # ECR repository name

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so k8s/app.yaml is found

echo "==> Deleting the app and its load balancer"  # Progress message
kubectl delete -f k8s/app.yaml --ignore-not-found  # Remove the Deployment and Service first, so AWS deletes the load balancer cleanly

echo "==> Deleting cluster $CLUSTER (~10–15 min)"  # Progress message
eksctl delete cluster --name "$CLUSTER" --region "$AWS_REGION" --wait  # Delete the cluster, node group, and VPC

# Optional: also delete the ECR repository and all its images (uncomment to use)
# aws ecr delete-repository --repository-name "$REPO" --force --region "$AWS_REGION"

echo "==> Remaining clusters (should be empty):"  # Progress message
aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text  # Any EKS clusters still in the region

echo "==> Remaining load balancers (should be empty):"  # Progress message
aws elb describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text  # Classic load balancers
aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].LoadBalancerName' --output text          # Application/network load balancers
