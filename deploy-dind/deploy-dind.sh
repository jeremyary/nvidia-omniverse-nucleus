#!/bin/bash
#################################################################################
# Deploy NVIDIA Omniverse Nucleus using Docker-in-Docker on OpenShift
#
# This script:
#   1. Creates ServiceAccount with privileged SCC
#   2. Creates ConfigMap with docker-compose files and crypto secrets
#   3. Updates /tmp/nucleus.env with LoadBalancer-compatible settings
#   4. Deploys the DIND pod
#################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load configuration from .env
if [ -f "$PROJECT_ROOT/.env" ]; then
    export $(grep -E '^(NAMESPACE|NGC_API_KEY)=' "$PROJECT_ROOT/.env" | xargs)
else
    echo "ERROR: .env file not found!"
    exit 1
fi

NAMESPACE="${NAMESPACE:-hacohen-omniverse}"

echo "======================================"
echo "Deploying Nucleus DIND"
echo "Namespace: $NAMESPACE"
echo "======================================"
echo ""

# Ensure namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "==> Namespace '$NAMESPACE' not found. Creating..."
    oc new-project "$NAMESPACE"
    echo "✓ Namespace created"
    echo ""
fi

# Check if crypto secrets exist, if not generate them
if ! oc get secret crypto-secrets -n "$NAMESPACE" &>/dev/null; then
    echo "==> Crypto secrets not found. Generating..."
    "$SCRIPT_DIR/generate-secrets.sh"
    echo "✓ Secrets generated"
    echo ""
fi

echo "==> Step 1: Creating ServiceAccount and SCC binding..."
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" "$SCRIPT_DIR/privileged-sa.yaml" | oc apply -f -
oc adm policy add-scc-to-user privileged -z nucleus-dind-sa -n "$NAMESPACE" 2>/dev/null || true
echo "✓ ServiceAccount created"

echo ""
echo "==> Step 2: Extracting crypto secrets..."
TEMP_SECRETS=$(mktemp -d)
oc get secret crypto-secrets -n "$NAMESPACE" -o json | \
  jq -r '.data | to_entries[] | "\(.key) \(.value)"' | \
  while read key value; do
    echo "$value" | base64 -d > "$TEMP_SECRETS/$key"
    echo "  Extracted: $key"
  done

echo ""
echo "==> Step 3: Finding NGC package files..."
# Look in upstream directory first, then fall back to project root
NGC_FILES=$(find "$PROJECT_ROOT/upstream" -maxdepth 1 -name "nucleus-stack-*.tar.gz" 2>/dev/null | sort | tail -1)
if [ -z "$NGC_FILES" ]; then
    NGC_FILES=$(find "$PROJECT_ROOT" -maxdepth 1 -name "nucleus-stack-*.tar.gz" 2>/dev/null | sort | tail -1)
fi

if [ -z "$NGC_FILES" ]; then
    echo "ERROR: NGC package not found in upstream/ or project root directory"
    echo "Please download nucleus-stack-*.tar.gz from NGC and place it in upstream/"
    rm -rf "$TEMP_SECRETS"
    exit 1
fi

echo "  Found: $NGC_FILES"

TEMP_EXTRACT=$(mktemp -d)
echo "  Extracting package..."
tar xzf "$NGC_FILES" -C "$TEMP_EXTRACT"

BASE_STACK=$(find "$TEMP_EXTRACT" -type d -name "base_stack" | head -1)

if [ -z "$BASE_STACK" ]; then
    echo "ERROR: Could not find base_stack directory in NGC package"
    rm -rf "$TEMP_SECRETS" "$TEMP_EXTRACT"
    exit 1
fi

echo "  Found base_stack: $BASE_STACK"

echo ""
echo "==> Step 4: Preparing nucleus.env for LoadBalancer..."
cp "$BASE_STACK/nucleus-stack.env" /tmp/nucleus.env

# Accept EULA (compatible with both GNU and BSD sed)
sed -i 's/^ACCEPT_EULA=.*/ACCEPT_EULA=1/' /tmp/nucleus.env
sed -i 's/^SECURITY_REVIEWED=.*/SECURITY_REVIEWED=1/' /tmp/nucleus.env

# Ensure CONTAINER_SUBNET is present
if ! grep -q "^CONTAINER_SUBNET=" /tmp/nucleus.env; then
    echo "CONTAINER_SUBNET=192.168.2.0/26" >> /tmp/nucleus.env
fi

echo "✓ nucleus.env prepared (EULA accepted, using default SERVER_IP_OR_HOST)"

echo ""
echo "==> Step 5: Creating nucleus-compose-files ConfigMap..."
oc delete configmap nucleus-compose-files -n "$NAMESPACE" --ignore-not-found=true

oc create configmap nucleus-compose-files \
  --from-file=nucleus-stack-no-ssl.yml="$BASE_STACK/nucleus-stack-no-ssl.yml" \
  --from-file=nucleus-stack.env=/tmp/nucleus.env \
  --from-file=federation.meta.blank.xml="$BASE_STACK/saml/federation.meta.blank.xml" \
  --from-file=auth_root_of_trust.pem="$TEMP_SECRETS/auth_root_of_trust_pri" \
  --from-file=auth_root_of_trust.pub="$TEMP_SECRETS/auth_root_of_trust_pub" \
  --from-file=auth_root_of_trust_lt.pem="$TEMP_SECRETS/auth_root_of_trust_lt_pri" \
  --from-file=auth_root_of_trust_lt.pub="$TEMP_SECRETS/auth_root_of_trust_lt_pub" \
  --from-file=pwd_salt="$TEMP_SECRETS/pwd_salt" \
  --from-file=lft_salt="$TEMP_SECRETS/lft_salt" \
  --from-file=svc_reg_token="$TEMP_SECRETS/svc_reg_token" \
  -n "$NAMESPACE"

echo "✓ ConfigMap created"

echo ""
echo "==> Step 6: Deploying PVC, Deployment, and Service..."
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" "$SCRIPT_DIR/nucleus-dind-simple.yaml" | oc apply -f -
echo "✓ Resources created"

echo ""
echo "==> Step 7: Waiting for LoadBalancer to provision..."
echo "(This may take 2-5 minutes for AWS ELB to provision)"
echo ""

for i in $(seq 1 60); do
  LB_HOST=$(oc get service nucleus-dind -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$LB_HOST" ]; then
    echo "✓ LoadBalancer ready: $LB_HOST"
    break
  fi
  echo "  Waiting for LoadBalancer... ($i/60)"
  sleep 5
done

if [ -z "$LB_HOST" ]; then
    echo ""
    echo "⚠ WARNING: LoadBalancer not ready yet"
    echo "   The pod will wait internally for the LoadBalancer hostname"
    echo "   Check status with: oc get svc nucleus-dind -n $NAMESPACE"
fi

echo ""
echo "==> Cleaning up temporary files..."
rm -rf "$TEMP_SECRETS" "$TEMP_EXTRACT"

echo ""
echo "======================================"
echo "✅ DIND deployment initiated!"
echo "======================================"
echo ""
echo "Monitor startup with:"
echo "  oc logs -f deployment/nucleus-dind -c nucleus-compose -n $NAMESPACE"
echo ""
echo "Check pod status:"
echo "  oc get pods -n $NAMESPACE -l app=nucleus-dind"
echo ""
echo "Get LoadBalancer URL:"
echo "  oc get svc nucleus-dind -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo ""
echo "IMPORTANT: Docker Compose startup inside the pod takes 5-10 minutes"
echo "           Wait for all containers to be healthy before accessing"
echo ""
