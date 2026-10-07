#!/usr/bin/env bash
# Get the load balancer address and call /hello.
# Usage: ./scripts/test-app.sh
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

URL=$(kubectl get svc eks-deploy-sample-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')  # Load balancer hostname of the Service
echo $URL                                # Show the address
curl -sSf --retry 10 --retry-delay 15 --retry-all-errors http://$URL/hello  # Call /hello; retry for ~2.5 min, and fail if it never answers
echo                                     # Newline after the JSON response
