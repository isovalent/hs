#!/usr/bin/env bash
#
# Hypershield Service Account Installer
# 
# This script creates a Kubernetes ServiceAccount with ClusterRole permissions
# for Hypershield resources.
#
# Usage:
#   curl -fsSL https://your-domain.com/sa-create.sh | bash
#
# Environment variables:
#   NAME                  Service account name (default: hypershield)
#   NAMESPACE             Kubernetes namespace (default: hypershield)
#   API_SERVER_PUBLIC_IP  (Optional) Public IP for API server URL override
#
# Examples:
#   # Install with defaults
#   curl -fsSL https://your-domain.com/sa-create.sh | bash
#
#   # Install to custom namespace
#   curl -fsSL https://your-domain.com/sa-create.sh | NAMESPACE=my-namespace bash
#
#   # Customize both name and namespace
#   curl -fsSL https://your-domain.com/sa-create.sh | NAME=my-sa NAMESPACE=my-ns bash
#
#   # Use public IP for API server in the token
#   curl -fsSL https://your-domain.com/sa-create.sh | API_SERVER_PUBLIC_IP=203.0.113.10 bash

read -r -d '' _SA_SECRET_TEMPLATE <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${NAME}
rules:
  - apiGroups:
      - cilium.io
    resources:
      - alertrules
      - sandboxpolicies
      - sandboxpoliciesnamespaced
      - tetragonnetworkpolicies
      - tetragonnetworkpoliciesnamespaced
      - tracingpolicies
      - tracingpoliciesnamespaced
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAME}
subjects:
  - kind: ServiceAccount
    name: ${NAME}
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: ${NAME}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${NAME}-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${NAME}
type: kubernetes.io/service-account-token
EOF

set -euo pipefail

# Check for kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH" >&2
    echo "Please install kubectl: https://kubernetes.io/docs/tasks/tools/" >&2
    exit 1
fi

# Check if a Kubernetes context is set
if ! kubectl config current-context &> /dev/null; then
    echo "Error: No Kubernetes context is currently set" >&2
    echo "Please configure kubectl to connect to a cluster:" >&2
    echo "  kubectl config get-contexts" >&2
    echo "  kubectl config use-context <context-name>" >&2
    exit 1
fi

# Allow override via environment variables with defaults
NAME=${NAME:-hypershield}
NAMESPACE=${NAMESPACE:-hypershield}

echo "Installing Hypershield ServiceAccount..."
echo "  Name: $NAME"
echo "  Namespace: $NAMESPACE"
echo ""

if ! eval "echo \"$_SA_SECRET_TEMPLATE\"" | kubectl apply -f -; then
    echo ""
    echo "✗ Failed to install Hypershield ServiceAccount" >&2
    exit 1
fi

echo ""
echo "✓ Successfully installed Hypershield ServiceAccount"
echo ""

# Wait for the secret to be created and token to be populated
echo "Waiting for secret to be created..."
SECRET_NAME="${NAME}-token"
SECRET_READY=false

for i in {1..30}; do
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        # Check if token field is populated (not just that secret exists)
        if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; then
            SECRET_READY=true
            break
        fi
    fi
    sleep 1
done

if [ "$SECRET_READY" = false ]; then
    echo ""
    echo "✗ Error: Secret was not created or token was not populated after 30 seconds" >&2
    echo "  This may indicate an issue with the Kubernetes token controller" >&2
    exit 1
fi

# Extract token and CA certificate
echo "Extracting credentials..."
TOKEN=$(kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.token}' | base64 --decode)
CA=$(kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.ca\.crt}' | base64 --decode)

# Verify we got valid data
if [ -z "$TOKEN" ] || [ -z "$CA" ]; then
    echo ""
    echo "✗ Error: Failed to extract token or CA certificate from secret" >&2
    echo "  Token length: ${#TOKEN}" >&2
    echo "  CA length: ${#CA}" >&2
    exit 1
fi
API_SERVER_INTERNAL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Determine API server URL (use public IP if provided)
if [ -n "${API_SERVER_PUBLIC_IP:-}" ]; then
    API_SERVER="https://${API_SERVER_PUBLIC_IP}"
    PORT=$(echo "$API_SERVER_INTERNAL" | sed -E 's/.*:([0-9]+)$/\1/')
    if [ -n "$PORT" ]; then
        API_SERVER="${API_SERVER}:${PORT}"
    fi
else
    API_SERVER="$API_SERVER_INTERNAL"
fi

# Create pipe-delimited base64-encoded auth string
# Use -w 0 on Linux, no flag needed on macOS (doesn't wrap by default)
if base64 --help 2>&1 | grep -q -- '-w'; then
    AUTH=$(echo "$API_SERVER|$TOKEN|$CA" | base64 -w 0)
else
    AUTH=$(echo "$API_SERVER|$TOKEN|$CA" | base64)
fi

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Copy the following authentication token:"
echo ""
echo "$AUTH"
echo ""
echo "Credentials extracted from:"
echo "  Namespace: $NAMESPACE"
echo "  Secret: $SECRET_NAME"
echo "  API Server: $API_SERVER"
echo ""
