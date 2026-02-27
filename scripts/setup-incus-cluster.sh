#!/usr/bin/env bash
set -euo pipefail

# MIAGE 2026 - K3S Cluster Setup on Incus
# Creates a 3-node K3S cluster: 1 server + 2 agents

CLUSTER_PREFIX="miage-lab"
IMAGE="images:debian/bookworm"
K3S_VERSION="v1.31.5+k3s1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Setting up MIAGE Lab K3S cluster on Incus"

# --- Create profiles ---
echo "==> Creating Incus profiles..."

incus profile show ${CLUSTER_PREFIX}-server &>/dev/null && incus profile delete ${CLUSTER_PREFIX}-server 2>/dev/null || true
incus profile create ${CLUSTER_PREFIX}-server 2>/dev/null || true
cat "${REPO_DIR}/incus/profiles/k3s-server.yaml" | incus profile edit ${CLUSTER_PREFIX}-server

incus profile show ${CLUSTER_PREFIX}-agent &>/dev/null && incus profile delete ${CLUSTER_PREFIX}-agent 2>/dev/null || true
incus profile create ${CLUSTER_PREFIX}-agent 2>/dev/null || true
cat "${REPO_DIR}/incus/profiles/k3s-agent.yaml" | incus profile edit ${CLUSTER_PREFIX}-agent

# --- Launch server node ---
echo "==> Launching K3S server node..."
if incus info ${CLUSTER_PREFIX}-server &>/dev/null; then
  echo "    Server node already exists, skipping..."
else
  incus launch ${IMAGE} ${CLUSTER_PREFIX}-server --profile ${CLUSTER_PREFIX}-server
  echo "    Waiting for network..."
  sleep 10

  # Wait for cloud-init and network
  for i in $(seq 1 30); do
    if incus exec ${CLUSTER_PREFIX}-server -- ip -4 addr show eth0 | grep -q "inet "; then
      break
    fi
    sleep 2
  done
fi

SERVER_IP=$(incus exec ${CLUSTER_PREFIX}-server -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "    Server IP: ${SERVER_IP}"

# --- Install K3S server ---
echo "==> Installing K3S server..."
incus exec ${CLUSTER_PREFIX}-server -- bash -c "
  if command -v k3s &>/dev/null; then
    echo 'K3S already installed'
    exit 0
  fi

  # Sysctl settings
  cat > /etc/sysctl.d/99-k3s.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
SYSCTL
  sysctl --system

  # Install deps
  apt-get update -qq && apt-get install -y -qq curl jq open-iscsi bash-completion >/dev/null 2>&1

  # Install K3S server (no default traefik, no servicelb - we manage our own)
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${K3S_VERSION}' sh -s - server \
    --disable traefik \
    --disable servicelb \
    --disable local-storage \
    --flannel-backend=none \
    --disable-network-policy \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --tls-san=${SERVER_IP} \
    --tls-san=kube.cloud-factory.co \
    --write-kubeconfig-mode=644
"

# Wait for K3S to be ready
echo "==> Waiting for K3S server to be ready..."
for i in $(seq 1 60); do
  if incus exec ${CLUSTER_PREFIX}-server -- k3s kubectl get nodes &>/dev/null; then
    break
  fi
  sleep 3
done

# --- Install Cilium as CNI ---
echo "==> Installing Cilium CLI and CNI..."
incus exec ${CLUSTER_PREFIX}-server -- bash -c "
  if command -v cilium &>/dev/null; then
    echo 'Cilium CLI already installed'
  else
    CILIUM_CLI_VERSION=\$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=arm64
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/\${CILIUM_CLI_VERSION}/cilium-linux-\${CLI_ARCH}.tar.gz
    tar xzvfC cilium-linux-\${CLI_ARCH}.tar.gz /usr/local/bin
    rm -f cilium-linux-\${CLI_ARCH}.tar.gz
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  cilium install --version 1.16.6 --set routingMode=native --set ipv4NativeRoutingCIDR=10.42.0.0/16 --set kubeProxyReplacement=true
  echo 'Waiting for Cilium to be ready...'
  cilium status --wait
"

# --- Get join token ---
K3S_TOKEN=$(incus exec ${CLUSTER_PREFIX}-server -- cat /var/lib/rancher/k3s/server/node-token)
echo "==> K3S token retrieved"

# --- Launch agent nodes ---
for i in 1 2; do
  AGENT_NAME="${CLUSTER_PREFIX}-agent-${i}"
  echo "==> Launching K3S agent node: ${AGENT_NAME}"

  if incus info ${AGENT_NAME} &>/dev/null; then
    echo "    Agent node ${AGENT_NAME} already exists, skipping launch..."
  else
    incus launch ${IMAGE} ${AGENT_NAME} --profile ${CLUSTER_PREFIX}-agent
    echo "    Waiting for network..."
    sleep 10
    for j in $(seq 1 30); do
      if incus exec ${AGENT_NAME} -- ip -4 addr show eth0 | grep -q "inet "; then
        break
      fi
      sleep 2
    done
  fi

  echo "==> Installing K3S agent on ${AGENT_NAME}..."
  incus exec ${AGENT_NAME} -- bash -c "
    if command -v k3s &>/dev/null; then
      echo 'K3S already installed'
      exit 0
    fi

    # Sysctl
    cat > /etc/sysctl.d/99-k3s.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
SYSCTL
    sysctl --system

    apt-get update -qq && apt-get install -y -qq curl jq open-iscsi bash-completion >/dev/null 2>&1

    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${K3S_VERSION}' sh -s - agent \
      --server https://${SERVER_IP}:6443 \
      --token '${K3S_TOKEN}'
  "
done

# --- Wait for all nodes ---
echo "==> Waiting for all nodes to be Ready..."
for i in $(seq 1 60); do
  READY_COUNT=$(incus exec ${CLUSTER_PREFIX}-server -- k3s kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)
  if [ "$READY_COUNT" -eq 3 ]; then
    break
  fi
  sleep 5
done

echo "==> Cluster nodes:"
incus exec ${CLUSTER_PREFIX}-server -- k3s kubectl get nodes -o wide

# --- Export kubeconfig ---
echo "==> Exporting kubeconfig..."
KUBECONFIG_DIR="${REPO_DIR}/.kubeconfig"
mkdir -p "${KUBECONFIG_DIR}"
incus exec ${CLUSTER_PREFIX}-server -- cat /etc/rancher/k3s/k3s.yaml | \
  sed "s/127.0.0.1/${SERVER_IP}/g" | \
  sed "s/default/miage-lab/g" > "${KUBECONFIG_DIR}/miage-lab.yaml"

echo "==> Kubeconfig exported to ${KUBECONFIG_DIR}/miage-lab.yaml"
echo "    Usage: export KUBECONFIG=${KUBECONFIG_DIR}/miage-lab.yaml"
echo ""
echo "==> MIAGE Lab K3S cluster setup complete!"
