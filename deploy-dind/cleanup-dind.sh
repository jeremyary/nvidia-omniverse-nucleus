#!/bin/bash
#################################################################################
# Cleanup NVIDIA Omniverse Nucleus DIND Deployment
#
# This script removes all DIND deployment resources from OpenShift.
# It provides options for partial or full cleanup.
#################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load configuration from .env
if [ -f "$PROJECT_ROOT/.env" ]; then
    export $(grep -E '^(NAMESPACE)=' "$PROJECT_ROOT/.env" | xargs)
else
    echo "ERROR: .env file not found!"
    exit 1
fi

NAMESPACE="${NAMESPACE:-hacohen-omniverse}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "Nucleus DIND Cleanup"
echo "Namespace: $NAMESPACE"
echo "======================================"
echo ""

# Check if resources exist
DEPLOYMENT_EXISTS=$(oc get deployment nucleus-dind -n "$NAMESPACE" 2>/dev/null | wc -l)
PVC_EXISTS=$(oc get pvc nucleus-dind-data -n "$NAMESPACE" 2>/dev/null | wc -l)

if [ "$DEPLOYMENT_EXISTS" -eq 0 ]; then
    echo "No DIND deployment found in namespace $NAMESPACE"
    exit 0
fi

# Ask for confirmation
echo -e "${YELLOW}WARNING: This will delete ALL resources:${NC}"
echo "  - Deployment: nucleus-dind"
echo "  - Service: nucleus-dind (LoadBalancer)"
echo "  - ConfigMap: nucleus-compose-files"
echo "  - ServiceAccount: nucleus-dind-sa"
echo "  - Secrets: crypto-secrets, ngc-pull-secret, ngc-api-key, master-password, service-password"
echo ""

if [ "$PVC_EXISTS" -gt 0 ]; then
    echo -e "${RED}The following will also be deleted (DATA LOSS!):${NC}"
    echo "  - PVC: nucleus-dind-data (500Gi of persistent data)"
    echo ""
fi

read -p "Do you want to proceed? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "==> Step 1: Deleting deployment..."
oc delete deployment nucleus-dind -n "$NAMESPACE" --ignore-not-found=true
echo "✓ Deployment deleted"

echo ""
echo "==> Step 2: Deleting LoadBalancer service..."
oc delete service nucleus-dind -n "$NAMESPACE" --ignore-not-found=true
echo "✓ Service deleted"

echo ""
echo "==> Step 3: Deleting ConfigMap..."
oc delete configmap nucleus-compose-files -n "$NAMESPACE" --ignore-not-found=true
echo "✓ ConfigMap deleted"

echo ""
echo "==> Step 4: Deleting PVC (persistent data)..."
if [ "$PVC_EXISTS" -gt 0 ]; then
    echo -e "${YELLOW}Deleting PVC with all data...${NC}"
    oc delete pvc nucleus-dind-data -n "$NAMESPACE" --ignore-not-found=true
    echo "✓ PVC deleted"
else
    echo "PVC not found, skipping"
fi

echo ""
echo "==> Step 5: Deleting ServiceAccount..."
oc delete serviceaccount nucleus-dind-sa -n "$NAMESPACE" --ignore-not-found=true
oc adm policy remove-scc-from-user privileged -z nucleus-dind-sa -n "$NAMESPACE" 2>/dev/null || true
echo "✓ ServiceAccount deleted"

echo ""
echo "==> Step 6: Deleting RoleBinding..."
oc delete rolebinding nucleus-service-reader-binding -n "$NAMESPACE" --ignore-not-found=true
echo "✓ RoleBinding deleted"

echo ""
echo "==> Step 7: Deleting Role..."
oc delete role nucleus-service-reader -n "$NAMESPACE" --ignore-not-found=true
echo "✓ Role deleted"

echo ""
echo "==> Step 8: Deleting Secrets..."
oc delete secret crypto-secrets ngc-pull-secret ngc-api-key master-password service-password -n "$NAMESPACE" --ignore-not-found=true
echo "✓ Secrets deleted"

echo ""
echo "==> Step 9: Checking for remaining resources..."
REMAINING=$(oc get all -n "$NAMESPACE" -l app=nucleus-dind 2>/dev/null | wc -l)
if [ "$REMAINING" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Some resources still exist:${NC}"
    oc get all -n "$NAMESPACE" -l app=nucleus-dind
else
    echo "✓ No DIND resources remaining"
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ Complete cleanup finished!${NC}"
echo "======================================"
echo ""
echo "All resources have been deleted."
echo "To redeploy: ./deploy-dind/deploy-dind.sh"
echo ""
