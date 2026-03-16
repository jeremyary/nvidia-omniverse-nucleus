#!/bin/bash

#################################################################################
# Generate OpenShift Secrets for NVIDIA Omniverse Nucleus
#
# This script generates all required secrets for Nucleus deployment on OpenShift.
# Based on NVIDIA's generate-sample-insecure-secrets.sh script.
#
# WARNING: For POC use only! In production, use proper secret management.
#################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="$PROJECT_ROOT/secrets-temp"

# Load configuration from .env
if [ -f "$PROJECT_ROOT/.env" ]; then
    export $(grep -E '^(NGC_API_KEY|NAMESPACE)=' "$PROJECT_ROOT/.env" | xargs)
else
    echo "ERROR: .env file not found!"
    exit 1
fi

# Use namespace from .env or default
NAMESPACE="${NAMESPACE:-hacohen-omniverse}"

echo "===================================="
echo "Generating Nucleus Secrets"
echo "Namespace: $NAMESPACE"
echo "===================================="

# Create temporary directory for secrets
mkdir -p "$SECRETS_DIR"

####################
# Generate Crypto Keys
####################

echo ""
echo "1. Generating short-term JWT signing keypair..."
if [ ! -f "$SECRETS_DIR/auth_root_of_trust.pem" ]; then
    openssl genrsa 4096 > "$SECRETS_DIR/auth_root_of_trust.pem" 2>/dev/null
    openssl rsa -pubout < "$SECRETS_DIR/auth_root_of_trust.pem" > "$SECRETS_DIR/auth_root_of_trust.pub" 2>/dev/null
    echo "   ✓ Generated auth_root_of_trust keypair"
else
    echo "   → Using existing auth_root_of_trust keypair"
fi

echo "2. Generating long-term JWT signing keypair..."
if [ ! -f "$SECRETS_DIR/auth_root_of_trust_lt.pem" ]; then
    openssl genrsa 4096 > "$SECRETS_DIR/auth_root_of_trust_lt.pem" 2>/dev/null
    openssl rsa -pubout < "$SECRETS_DIR/auth_root_of_trust_lt.pem" > "$SECRETS_DIR/auth_root_of_trust_lt.pub" 2>/dev/null
    echo "   ✓ Generated auth_root_of_trust_lt keypair"
else
    echo "   → Using existing auth_root_of_trust_lt keypair"
fi

echo "3. Generating discovery service registration token..."
if [ ! -f "$SECRETS_DIR/svc_reg_token" ]; then
    dd if=/dev/urandom bs=1 count=128 2>/dev/null | xxd -plain -c 256 > /tmp/svc_reg_token_tmp
    dd if=/tmp/svc_reg_token_tmp of="$SECRETS_DIR/svc_reg_token" bs=1 count=256 2>/dev/null
    rm /tmp/svc_reg_token_tmp
    echo "   ✓ Generated svc_reg_token"
else
    echo "   → Using existing svc_reg_token"
fi

echo "4. Generating password salt..."
if [ ! -f "$SECRETS_DIR/pwd_salt" ]; then
    dd if=/dev/urandom bs=1 count=4 2>/dev/null | xxd -plain -c 256 > /tmp/pwd_salt_tmp
    dd if=/tmp/pwd_salt_tmp of="$SECRETS_DIR/pwd_salt" bs=1 count=8 2>/dev/null
    rm /tmp/pwd_salt_tmp
    echo "   ✓ Generated pwd_salt"
else
    echo "   → Using existing pwd_salt"
fi

echo "5. Generating LFT salt..."
if [ ! -f "$SECRETS_DIR/lft_salt" ]; then
    dd if=/dev/urandom bs=1 count=128 2>/dev/null | xxd -plain -c 256 > /tmp/lft_salt_tmp
    dd if=/tmp/lft_salt_tmp of="$SECRETS_DIR/lft_salt" bs=1 count=256 2>/dev/null
    rm /tmp/lft_salt_tmp
    echo "   ✓ Generated lft_salt"
else
    echo "   → Using existing lft_salt"
fi

####################
# Create OpenShift Secrets
####################

echo ""
echo "===================================="
echo "Creating OpenShift Secrets"
echo "===================================="

# 1. NGC Pull Secret
echo ""
echo "1. NGC Pull Secret..."
if [ -z "$NGC_API_KEY" ]; then
    echo "   ERROR: NGC_API_KEY not found in .env file!"
    exit 1
fi

oc create secret docker-registry ngc-pull-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f - \
    && echo "   ✓ Created ngc-pull-secret"

echo "   Creating NGC API key secret for container login..."
oc create secret generic ngc-api-key \
    --from-literal=NGC_API_KEY="$NGC_API_KEY" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f - \
    && echo "   ✓ Created ngc-api-key secret"

# 2. Master Password Secret
echo "2. Master Password Secret..."
MASTER_PASSWORD=${MASTER_PASSWORD:-"omniverse123"}
oc create secret generic master-password \
    --from-literal=password="$MASTER_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f - \
    && echo "   ✓ Created master-password (default: omniverse123)"

# 3. Service Password Secret
echo "3. Service Password Secret..."
SERVICE_PASSWORD=${SERVICE_PASSWORD:-"service123"}
oc create secret generic service-password \
    --from-literal=password="$SERVICE_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f - \
    && echo "   ✓ Created service-password (default: service123)"

# 4. Crypto Secrets
echo "4. Crypto Secrets (JWT keypairs and tokens)..."
oc create secret generic crypto-secrets \
    --from-file=auth_root_of_trust_pri="$SECRETS_DIR/auth_root_of_trust.pem" \
    --from-file=auth_root_of_trust_pub="$SECRETS_DIR/auth_root_of_trust.pub" \
    --from-file=auth_root_of_trust_lt_pri="$SECRETS_DIR/auth_root_of_trust_lt.pem" \
    --from-file=auth_root_of_trust_lt_pub="$SECRETS_DIR/auth_root_of_trust_lt.pub" \
    --from-file=svc_reg_token="$SECRETS_DIR/svc_reg_token" \
    --from-file=pwd_salt="$SECRETS_DIR/pwd_salt" \
    --from-file=lft_salt="$SECRETS_DIR/lft_salt" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f - \
    && echo "   ✓ Created crypto-secrets"

echo ""
echo "===================================="
echo "✅ All secrets created successfully!"
echo "===================================="
echo ""
echo "Secrets stored in namespace: $NAMESPACE"
echo "Temporary files in: $SECRETS_DIR"
echo ""
echo "WARNING: These are sample insecure secrets for POC only."
echo "         For production, regenerate with proper key management."
echo ""
