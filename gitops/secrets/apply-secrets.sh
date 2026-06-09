#!/bin/bash
set -euo pipefail

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

sops -d gitops/secrets/argocd/ghcr-image-updater.enc.yaml | kubectl apply -f -
sops -d gitops/secrets/argocd/git-write-token.enc.yaml | kubectl apply -f -
sops -d gitops/secrets/go-service/ghcr-pull.enc.yaml | kubectl apply -f -
sops -d gitops/secrets/node-service/ghcr-pull.enc.yaml | kubectl apply -f -
sops -d gitops/secrets/monitoring/alert-manager-telegram-bot-token.enc.yaml | kubectl apply -f -
