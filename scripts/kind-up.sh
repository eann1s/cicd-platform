#!/bin/bash

set -euo pipefail

CLUSTER_NAME="${1:-argocd}"

context_exists() {
    kubectl config get-contexts -o name | grep -Fxq "kind-$CLUSTER_NAME"
}

create_cluster() {
    kind create cluster --name "$CLUSTER_NAME"
    kubectl config use-context kind-"$CLUSTER_NAME"
}

delete_cluster() {
    kind delete cluster --name "$CLUSTER_NAME" || true
}

recreate_cluster() {
    delete_cluster
    create_cluster
}

api_up() {
    kubectl --context "kind-$CLUSTER_NAME" get --raw=/readyz >/dev/null 2>&1
}

start_stopped_control_plane() {
    docker start "${CLUSTER_NAME}-control-plane" > /dev/null 2>&1
}

ensure_cluster_ready() {
    if ! kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
        create_cluster
        return
    fi

    if ! context_exists; then
        recreate_cluster
        return
    fi

    kubectl config use-context "kind-$CLUSTER_NAME"

    if ! api_up; then
        echo "API server is down, trying to start the stopped container first..."
        start_stopped_control_plane
        for _ in $(seq 1 10); do
            if api_up; then
                break
            fi
            sleep 1
        done
        if ! api_up; then
            echo "Container is still down or doesn't exist, so recreating cluster..."
            recreate_cluster
        fi
    fi
}

ensure_cluster_ready
kubectl config set-context --current --namespace default

