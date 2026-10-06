# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Acceptance tests for keeping the `infra-deployments` repository updated with the latest Enterprise Contract (Conforma) components. Uses BDD (Behavior-Driven Development) with Godog/Cucumber to validate that EC components deploy and function correctly in a KinD (Kubernetes in Docker) cluster.

## Essential Commands

```bash
make acceptance              # Run all acceptance tests (30m timeout)
make acceptance-persist      # Run tests and keep the KinD cluster alive for debugging
make acceptance-kubeconfig   # Export KUBECONFIG for a persisted cluster: eval $(make acceptance-kubeconfig)
```

Run a specific feature:
```bash
cd acceptance && go test -count=1 -v -timeout 30m ./... -run TestFeatures/feature_name
```

## Architecture

```
acceptance/
├── acceptance_test.go       # Test runner and step definitions (Godog)
├── conforma.yaml            # EC policy configuration for validation
├── conforma-ta.yaml         # EC policy configuration for Trusted Artifacts validation
├── prepare-snapshot.yaml    # Snapshot preparation configuration
├── pub.key                  # Public key for signature verification
├── kubernetes/              # Kubernetes manifests applied during tests
├── kustomize/               # Kustomize overlays for test environment
├── testenv/                 # KinD cluster setup and test environment utilities
├── log/                     # Test log output
├── go.mod                   # Separate Go module for acceptance tests
features/
├── validate_golden.feature         # BDD scenarios for standard validation
├── validate_golden_ta.feature      # BDD scenarios for Trusted Artifacts validation
```

## Test Environment

Tests spin up a KinD cluster, deploy EC components via kustomize, and run validation scenarios against golden container images. Use `acceptance-persist` + `acceptance-kubeconfig` to keep the cluster running for manual debugging.
