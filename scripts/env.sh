# Shared settings for Steps 4–9. Load into the current terminal with: source ./scripts/env.sh
# (must be sourced, not run as ./scripts/env.sh — a script can't set variables in your terminal)
export AWS_REGION=us-west-1              # AWS region for ECR and EKS
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)  # AWS account ID of the current credentials
export REPO=eks-deploy-sample            # ECR repository name
export IMAGE_BASE=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO           # Image address without the tag

echo "AWS_REGION=$AWS_REGION"            # Show the values so you can see they loaded
echo "ACCOUNT_ID=$ACCOUNT_ID"
echo "REPO=$REPO"
echo "IMAGE_BASE=$IMAGE_BASE"
