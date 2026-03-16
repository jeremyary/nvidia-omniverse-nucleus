# Notes and Changes

A few adjustments we made while working through the DIND deployment, plus an
alternative native Kubernetes approach we put together. Sharing in case any of
it is useful.

## DIND deployment fixes

These are small tweaks we ran into while deploying on a fresh OpenShift cluster.

### 1. `sed -i` portability (`deploy-dind.sh`)

`sed -i ''` is BSD/macOS syntax. On Linux (GNU sed), the empty string gets
treated as a filename. Changed to `sed -i` which works on both.

### 2. Namespace auto-creation (`deploy-dind.sh`)

Added a check to create the namespace via `oc new-project` if it doesn't
already exist, so the script doesn't fail partway through on a fresh cluster.

### 3. Parameterized namespace in YAMLs

`privileged-sa.yaml` and `nucleus-dind-simple.yaml` had a specific namespace
hardcoded. Replaced with `NAMESPACE_PLACEHOLDER` so the deploy script can
substitute the value from `.env` at apply time.

### 4. NGC API key moved to a secret

The NGC API key was inline in the deployment YAML. Moved it to a generic
secret (`ngc-api-key`) created in `generate-secrets.sh`, referenced via
`secretKeyRef` in the pod spec.

### 5. Cleanup script updated (`cleanup-dind.sh`)

Updated to delete all five secrets on teardown, not just `crypto-secrets`.

### Suggestion: readiness probe

The pod reports Ready immediately, but the inner Docker Compose services take
several minutes to pull and start. A readiness probe (e.g. exec-based using
`docker-compose ps`) would prevent routing traffic before services are up.

## Native Kubernetes deployment (`deploy-native/`)

We also put together a Helm-based deployment that runs each Nucleus service as
its own Kubernetes Deployment, without Docker-in-Docker or privileged
containers. Uses OpenShift Routes for ingress instead of a cloud load balancer.

See [`deploy-native/README.md`](../deploy-native/README.md) for details.
