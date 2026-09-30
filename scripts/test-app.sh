#!/usr/bin/env bash
# Get the load balancer address and call /hello.
# Usage: ./scripts/test-app.sh
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

URL=$(kubectl get svc eks-deploy-sample-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')  # Load balancer hostname of the Service
echo $URL                                # Show the address
curl http://$URL/hello                   # Call the /hello endpoint
echo                                     # Newline after the JSON response
