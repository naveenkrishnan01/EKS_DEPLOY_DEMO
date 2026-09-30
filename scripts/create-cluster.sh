#!/usr/bin/env bash
# Create the EKS cluster and managed node group with eksctl, then point kubectl at it (~15–20 min).
# Usage: ./scripts/create-cluster.sh    (override with e.g. NODE_TYPE=c7i-flex.large ./scripts/create-cluster.sh)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/create-cluster.sh
CLUSTER="${CLUSTER:-eks-sample-cluster}" # EKS cluster name
NODEGROUP="${NODEGROUP:-eks-nodes}"     # Managed node group name
NODE_TYPE="${NODE_TYPE:-m7i-flex.large}" # EC2 instance type for worker nodes (must be free-tier eligible on the Free plan)
NODES="${NODES:-2}"                      # Number of worker nodes to start with

if aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then  # Skip creation if the cluster already exists
  echo "==> Cluster $CLUSTER already exists in $AWS_REGION, skipping create"                 # Progress message
else
  echo "==> Creating cluster $CLUSTER in $AWS_REGION with $NODES x $NODE_TYPE (~15–20 min)"  # Progress message
  eksctl create cluster \
    --name "$CLUSTER" \
    --region "$AWS_REGION" \
    --nodegroup-name "$NODEGROUP" \
    --node-type "$NODE_TYPE" \
    --nodes "$NODES" --nodes-min 1 --nodes-max 3 \
    --managed                            # Build VPC, control plane, and a managed node group via CloudFormation
fi

echo "==> Pointing kubectl at $CLUSTER"  # Progress message
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"  # Write/refresh the cluster entry in ~/.kube/config

echo "==> Nodes:"                        # Progress message
kubectl get nodes                        # Should list the worker nodes with STATUS Ready
