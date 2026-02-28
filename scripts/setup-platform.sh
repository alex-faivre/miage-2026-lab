#!/usr/bin/env bash
set -euo pipefail

# MIAGE 2026 - Platform Stack Installation
# Installs: local-path-provisioner, cert-manager, Traefik, ArgoCD, Authentik, Teleport, vcluster

CONTAINER="${1:-miage-lab-server}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

push_values() {
  local component="$1"
  incus file push "${REPO_DIR}/platform/${component}/values.yaml" "${CONTAINER}/opt/platform/${component}/values.yaml" --create-dirs
}

helm_cmd() {
  incus exec "${CONTAINER}" -- bash -c "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && $1"
}

echo "==> Installing MIAGE 2026 Platform Stack"

# --- Add Helm repos ---
echo "==> Adding Helm repositories..."
helm_cmd "
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo add authentik https://charts.goauthentik.io 2>/dev/null || true
helm repo add teleport https://charts.releases.teleport.dev 2>/dev/null || true
helm repo add loft-sh https://charts.loft.sh 2>/dev/null || true
helm repo update
"

# --- local-path-provisioner ---
echo "==> Installing local-path-provisioner..."
helm_cmd "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml 2>/dev/null || true"
helm_cmd "kubectl patch storageclass local-path -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}' 2>/dev/null || true"

# --- cert-manager ---
echo "==> Installing cert-manager..."
push_values cert-manager
helm_cmd "helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  -f /opt/platform/cert-manager/values.yaml \
  --set startupapicheck.enabled=false \
  --wait --timeout 3m"

# --- Traefik ---
echo "==> Installing Traefik..."
push_values traefik
helm_cmd "helm upgrade --install traefik traefik/traefik \
  -n traefik --create-namespace \
  -f /opt/platform/traefik/values.yaml \
  --wait --timeout 3m"

# --- ArgoCD ---
echo "==> Installing ArgoCD..."
push_values argocd
helm_cmd "helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f /opt/platform/argocd/values.yaml \
  --wait --timeout 5m"

# --- Authentik ---
echo "==> Installing Authentik..."
push_values authentik
helm_cmd "helm upgrade --install authentik authentik/authentik \
  -n authentik --create-namespace \
  -f /opt/platform/authentik/values.yaml \
  --wait --timeout 5m"

# --- Teleport ---
echo "==> Installing Teleport..."
push_values teleport
helm_cmd "helm upgrade --install teleport-cluster teleport/teleport-cluster \
  -n teleport --create-namespace \
  -f /opt/platform/teleport/values.yaml \
  --wait --timeout 5m"

# --- vcluster ---
echo "==> Installing vcluster (student-0)..."
push_values vcluster
helm_cmd "helm upgrade --install vcluster-student-0 loft-sh/vcluster \
  -n vcluster-student-0 --create-namespace \
  -f /opt/platform/vcluster/values.yaml \
  --wait --timeout 5m"

# --- CoreDNS custom entries ---
echo "==> Configuring CoreDNS for internal DNS resolution..."
TRAEFIK_IP=$(helm_cmd "kubectl get svc -n traefik traefik -o jsonpath='{.spec.clusterIP}'")
TELEPORT_IP=$(helm_cmd "kubectl get svc -n teleport teleport-cluster -o jsonpath='{.spec.clusterIP}'")

helm_cmd "cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  kube-cloud-factory.server: |
    kube.cloud-factory.co:53 {
      hosts {
        ${TRAEFIK_IP} auth.kube.cloud-factory.co
        ${TRAEFIK_IP} argocd.kube.cloud-factory.co
        ${TELEPORT_IP} teleport.kube.cloud-factory.co
      }
    }
EOF"
helm_cmd "kubectl rollout restart deployment coredns -n kube-system"

# --- Proxy devices ---
echo "==> Configuring Incus proxy devices..."
incus config device add "${CONTAINER}" http proxy listen=tcp:0.0.0.0:8080 connect=tcp:127.0.0.1:30080 2>/dev/null || true
incus config device add "${CONTAINER}" https proxy listen=tcp:0.0.0.0:8443 connect=tcp:127.0.0.1:30443 2>/dev/null || true
incus config device add "${CONTAINER}" k8s-api proxy listen=tcp:0.0.0.0:26443 connect=tcp:127.0.0.1:6443 2>/dev/null || true

TELEPORT_NP=$(helm_cmd "kubectl get svc -n teleport teleport-cluster -o jsonpath='{.spec.ports[0].nodePort}'")
incus config device add "${CONTAINER}" proxy-teleport proxy listen=tcp:0.0.0.0:3080 connect=tcp:127.0.0.1:${TELEPORT_NP} 2>/dev/null || true

echo ""
echo "==> Platform stack installation complete!"
echo ""
echo "Add to /etc/hosts:"
echo "127.0.0.1 argocd.kube.cloud-factory.co auth.kube.cloud-factory.co teleport.kube.cloud-factory.co"
echo ""
echo "Access points:"
echo "  ArgoCD:    https://argocd.kube.cloud-factory.co:8443"
echo "  Authentik: http://auth.kube.cloud-factory.co:8080"
echo "  Teleport:  https://teleport.kube.cloud-factory.co:3080"
echo "  K3S API:   https://localhost:26443"
