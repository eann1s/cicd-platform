SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

APP ?= go-service
CMD_DIR ?= ./cmd/$(APP)
BIN_DIR ?= ./bin

.PHONY: help deps tidy test build run clean

help: ## Display this help
	@awk 'BEGIN {FS = ":.*?##"} /^[a-zA-Z_-]+:.*?##/ {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deps: ## Install dependencies
	go mod download

tidy: ## Tidy
	go mod tidy

test: ## Run tests
	go test -v ./...

build: ## Build
	go build -o $(BIN_DIR)/$(APP) $(CMD_DIR)

run: build ## Run
	$(BIN_DIR)/$(APP)

clean: ## Clean
	rm -rf $(BIN_DIR)
