#!/usr/bin/env bash
set -euo pipefail

# Setup Teleport GitHub OAuth connector and roles
# Usage: ./scripts/setup-teleport-auth.sh <github_client_id> <github_client_secret>

GITHUB_CLIENT_ID="${1:?Usage: $0 <github_client_id> <github_client_secret>}"
GITHUB_CLIENT_SECRET="${2:?Usage: $0 <github_client_id> <github_client_secret>}"
CONTAINER="${3:-miage-lab-server}"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kubeconfig/miage-lab.yaml}"

echo "==> Configuring Teleport GitHub connector..."

TELEPORT_AUTH_POD=$(incus exec "${CONTAINER}" -- kubectl get pods -n teleport \
  -l app.kubernetes.io/component=auth \
  -o jsonpath='{.items[0].metadata.name}' \
  --kubeconfig=/etc/rancher/k3s/k3s.yaml)

echo "Teleport auth pod: ${TELEPORT_AUTH_POD}"

# Create kube-access role
echo "==> Creating kube-access role..."
incus exec "${CONTAINER}" -- bash -c "cat <<'YAML' | kubectl exec -i -n teleport ${TELEPORT_AUTH_POD} --kubeconfig=/etc/rancher/k3s/k3s.yaml -- tctl create -f -
kind: role
version: v7
metadata:
  name: kube-access
spec:
  allow:
    kubernetes_groups:
      - system:masters
    kubernetes_labels:
      \"*\": \"*\"
    kubernetes_resources:
      - kind: \"*\"
        namespace: \"*\"
        name: \"*\"
        verbs: [\"*\"]
  deny: {}
YAML"

# Create GitHub connector
echo "==> Creating GitHub connector..."
incus exec "${CONTAINER}" -- bash -c "cat <<YAML | kubectl exec -i -n teleport ${TELEPORT_AUTH_POD} --kubeconfig=/etc/rancher/k3s/k3s.yaml -- tctl create -f -
kind: github
version: v3
metadata:
  name: github
spec:
  client_id: ${GITHUB_CLIENT_ID}
  client_secret: ${GITHUB_CLIENT_SECRET}
  display: GitHub - alex-faivre-formation
  redirect_url: https://teleport.kube.cloud-factory.co:3080/v1/webapi/github/callback
  teams_to_roles:
    - organization: alex-faivre-formation
      team: admins
      roles:
        - admin
        - access
        - editor
    - organization: alex-faivre-formation
      team: students
      roles:
        - access
        - kube-access
YAML"

echo "==> Teleport auth setup complete!"
echo ""
echo "Next steps:"
echo "  1. Create 'admins' and 'students' teams in the alex-faivre-formation GitHub org"
echo "  2. Add yourself to the 'admins' team"
echo "  3. Add students to the 'students' team"
echo "  4. Access Teleport at https://teleport.kube.cloud-factory.co:3080"
echo "  5. Click 'Login with GitHub'"
