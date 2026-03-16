#!/bin/bash
#################################################################################
# Deploy NVIDIA Omniverse Nucleus natively on OpenShift via Helm
#
# Prerequisites:
#   - oc login to cluster
#   - .env file at project root with NGC_API_KEY and NAMESPACE
#
# This script handles:
#   1. Namespace creation
#   2. NGC pull secret
#   3. Crypto secret generation (JWT keys, tokens, salts)
#   4. Helm install with OpenShift Routes
#################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="$PROJECT_ROOT/secrets-temp"

# Load configuration from .env
if [ -f "$PROJECT_ROOT/.env" ]; then
    export $(grep -E '^(NGC_API_KEY|NAMESPACE)=' "$PROJECT_ROOT/.env" | xargs)
else
    echo "ERROR: .env file not found at project root!"
    echo "Create one with:"
    echo "  NGC_API_KEY=your_key_here"
    echo "  NAMESPACE=omniverse-nucleus"
    exit 1
fi

NAMESPACE="${NAMESPACE:-omniverse-nucleus}"

echo "======================================"
echo "Deploying Nucleus (Native Kubernetes)"
echo "Namespace: $NAMESPACE"
echo "======================================"
echo ""

# Step 1: Ensure namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "==> Creating namespace '$NAMESPACE'..."
    oc new-project "$NAMESPACE"
    echo "✓ Namespace created"
    echo ""
else
    echo "==> Namespace '$NAMESPACE' exists"
    oc project "$NAMESPACE"
    echo ""
fi

# Step 2: Grant anyuid SCC (NVIDIA images require running as root)
# Scoped to a dedicated 'nucleus' SA — does NOT affect other workloads in the namespace
echo "==> Granting anyuid SCC to nucleus service account..."
oc adm policy add-scc-to-user anyuid -z nucleus -n "$NAMESPACE" 2>/dev/null || true
echo "✓ anyuid SCC granted"
echo ""

# Step 3: Create NGC pull secret
if ! oc get secret ngc-pull-secret -n "$NAMESPACE" &>/dev/null; then
    echo "==> Creating NGC pull secret..."
    oc create secret docker-registry ngc-pull-secret \
        --docker-server=nvcr.io \
        --docker-username='$oauthtoken' \
        --docker-password="$NGC_API_KEY" \
        -n "$NAMESPACE"
    echo "✓ NGC pull secret created"
    echo ""
else
    echo "==> NGC pull secret exists"
    echo ""
fi

# Step 4: Generate crypto secrets if they don't exist
if ! oc get secret crypto-secrets -n "$NAMESPACE" &>/dev/null; then
    echo "==> Generating crypto secrets..."
    mkdir -p "$SECRETS_DIR"

    # Short-term JWT keypair
    if [ ! -f "$SECRETS_DIR/auth_root_of_trust.pem" ]; then
        openssl genrsa 4096 > "$SECRETS_DIR/auth_root_of_trust.pem" 2>/dev/null
        openssl rsa -pubout < "$SECRETS_DIR/auth_root_of_trust.pem" > "$SECRETS_DIR/auth_root_of_trust.pub" 2>/dev/null
    fi

    # Long-term JWT keypair
    if [ ! -f "$SECRETS_DIR/auth_root_of_trust_lt.pem" ]; then
        openssl genrsa 4096 > "$SECRETS_DIR/auth_root_of_trust_lt.pem" 2>/dev/null
        openssl rsa -pubout < "$SECRETS_DIR/auth_root_of_trust_lt.pem" > "$SECRETS_DIR/auth_root_of_trust_lt.pub" 2>/dev/null
    fi

    # Discovery registration token
    if [ ! -f "$SECRETS_DIR/svc_reg_token" ]; then
        dd if=/dev/urandom bs=1 count=128 2>/dev/null | xxd -plain -c 256 > /tmp/svc_reg_token_tmp
        dd if=/tmp/svc_reg_token_tmp of="$SECRETS_DIR/svc_reg_token" bs=1 count=256 2>/dev/null
        rm /tmp/svc_reg_token_tmp
    fi

    # Password salt
    if [ ! -f "$SECRETS_DIR/pwd_salt" ]; then
        dd if=/dev/urandom bs=1 count=4 2>/dev/null | xxd -plain -c 256 > /tmp/pwd_salt_tmp
        dd if=/tmp/pwd_salt_tmp of="$SECRETS_DIR/pwd_salt" bs=1 count=8 2>/dev/null
        rm /tmp/pwd_salt_tmp
    fi

    # LFT salt
    if [ ! -f "$SECRETS_DIR/lft_salt" ]; then
        dd if=/dev/urandom bs=1 count=128 2>/dev/null | xxd -plain -c 256 > /tmp/lft_salt_tmp
        dd if=/tmp/lft_salt_tmp of="$SECRETS_DIR/lft_salt" bs=1 count=256 2>/dev/null
        rm /tmp/lft_salt_tmp
    fi

    oc create secret generic crypto-secrets \
        --from-file=auth_root_of_trust_pri="$SECRETS_DIR/auth_root_of_trust.pem" \
        --from-file=auth_root_of_trust_pub="$SECRETS_DIR/auth_root_of_trust.pub" \
        --from-file=auth_root_of_trust_lt_pri="$SECRETS_DIR/auth_root_of_trust_lt.pem" \
        --from-file=auth_root_of_trust_lt_pub="$SECRETS_DIR/auth_root_of_trust_lt.pub" \
        --from-file=svc_reg_token="$SECRETS_DIR/svc_reg_token" \
        --from-file=pwd_salt="$SECRETS_DIR/pwd_salt" \
        --from-file=lft_salt="$SECRETS_DIR/lft_salt" \
        -n "$NAMESPACE"
    echo "✓ Crypto secrets created"
    echo ""
else
    echo "==> Crypto secrets exist"
    echo ""
fi

# Step 5: Determine the Route hostname
# Use the cluster's apps domain to construct the Route hostname
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
if [ -z "$CLUSTER_DOMAIN" ]; then
    echo "ERROR: Could not determine cluster apps domain"
    exit 1
fi
SERVER_HOST="nucleus.${CLUSTER_DOMAIN}"
echo "==> Server hostname: $SERVER_HOST"
echo ""

# Step 6: Helm install
echo "==> Installing Helm chart..."
helm upgrade --install nucleus "$SCRIPT_DIR" \
    --namespace "$NAMESPACE" \
    --set serverHost="$SERVER_HOST" \
    --wait \
    --timeout 5m

echo ""
echo "======================================"
echo "✅ Nucleus deployed (native Kubernetes)!"
echo "======================================"
echo ""
echo "Navigator UI:  http://$SERVER_HOST"
echo ""
echo "Check pod status:"
echo "  oc get pods -n $NAMESPACE"
echo ""
echo "Login: omniverse / omniverse123"
echo ""
