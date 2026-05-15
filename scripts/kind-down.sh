#!/bin/bash

set -euo pipefail

CLUSTER_NAME="${1:-argocd}"

if kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
    kind delete cluster --name "$CLUSTER_NAME"
else
    echo "Cluster $CLUSTER_NAME does not exist"
fi
