#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_ROOT/.env" ]; then
    export $(grep -E '^(NAMESPACE)=' "$PROJECT_ROOT/.env" | xargs)
fi

NAMESPACE="${NAMESPACE:-omniverse-nucleus}"

echo "======================================"
echo "Nucleus Native Cleanup"
echo "Namespace: $NAMESPACE"
echo "======================================"
echo ""

read -p "This will delete ALL Nucleus resources including data. Proceed? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "==> Uninstalling Helm release..."
helm uninstall nucleus -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
echo "✓ Helm release removed"

echo ""
echo "==> Deleting PVC..."
oc delete pvc nucleus-data -n "$NAMESPACE" --ignore-not-found=true
echo "✓ PVC deleted"

echo ""
echo "==> Deleting secrets..."
oc delete secret crypto-secrets ngc-pull-secret -n "$NAMESPACE" --ignore-not-found=true
echo "✓ Secrets deleted"

echo ""
echo "==> Removing SCC grant..."
oc adm policy remove-scc-from-user anyuid -z nucleus -n "$NAMESPACE" 2>/dev/null || true
echo "✓ SCC removed"

echo ""
echo "======================================"
echo "✅ Cleanup complete!"
echo "======================================"
