#!/usr/bin/env bash

KIND_CLUSTER="${KIND_CLUSTER:-apiextraction}"

_kind() {
    if ! kind get clusters | grep -q "$KIND_CLUSTER"; then
        kind create cluster "$KIND_CLUSTER"
    fi

    kind export kubeconfig --name "$KIND_CLUSTER" --kubeconfig ./kind.kubeconfig

    kubectl apply --kubeconfig ./kind.kubeconfig -k ./kind/manifests
}

_kind
