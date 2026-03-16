# Nucleus Native Kubernetes Deployment

Deploys Nucleus as individual Kubernetes workloads on
OpenShift, using Helm charts and OpenShift Routes, no need for DIND or privileged containers.

## What this deploys

12 services, each as its own Deployment + Service:

| Service | Purpose |
|---------|---------|
| API | Core Nucleus server (file operations, versioning) |
| Auth | Authentication and user management |
| Discovery | Service registry for inter-service and client discovery |
| LFT | Large File Transfer |
| LFT-LB | Nginx load balancer in front of LFT |
| Log Processor | Log rotation and metrics processing |
| Navigator | Web UI |
| Resolver Cache | S3/mount resolver caching |
| Search | Full-text search |
| Tagging | Asset tagging |
| Thumbnails | Thumbnail generation |
| MonPX | Metrics/monitoring proxy |

Plus:
- 8 OpenShift Routes (path-based routing on a single hostname)
- Shared PVC for data persistence
- Crypto secrets (JWT keypairs, tokens, salts)
- Dedicated ServiceAccount with `anyuid` SCC

## Prerequisites

- `oc` CLI, logged in to an OpenShift cluster
- `helm` CLI (v3+)
- `openssl` and `xxd` (for secret generation)
- NGC API key (requires NVIDIA enterprise account)

## Setup

1. Create a `.env` file at the **project root** (one level up from this directory):

```
NGC_API_KEY=your_ngc_api_key_here
NAMESPACE=omniverse-nucleus
```

2. Deploy:

```bash
./deploy-native/deploy.sh
```

The script handles everything automatically:
- Creates the namespace if needed
- Grants `anyuid` SCC to a dedicated `nucleus` service account
- Creates the NGC pull secret
- Generates JWT keypairs, discovery tokens, and salts
- Detects the cluster's apps domain and constructs the Route hostname
- Runs `helm upgrade --install`

3. Access Navigator at the URL printed by the script (typically `http://nucleus.<apps-domain>`).

Default login: `omniverse` / `omniverse123`

## Cleanup

```bash
./deploy-native/cleanup.sh
```

Removes the Helm release, PVC, secrets, and SCC grant. Prompts for confirmation first.

## Architecture notes

### Why `anyuid`?

NVIDIA's container images use `/root/eula.sh` as their entrypoint, which
requires running as UID 0. OpenShift's default `restricted` SCC blocks this.
The `anyuid` SCC is the minimum elevation needed — it allows running as root
but still enforces SELinux, seccomp, and capability restrictions. The grant is
scoped to a dedicated `nucleus` ServiceAccount so other workloads in the
namespace are unaffected.

### Routing

All external traffic goes through OpenShift Routes on a single hostname with
path-based routing:

| Path | Service |
|------|---------|
| `/` | Navigator (web UI) |
| `/omni/api` | API |
| `/omni/auth` | Auth (WebSocket) |
| `/omni/auth-login` | Auth (login form) |
| `/omni/discovery` | Discovery |
| `/omni/lft` | LFT (file upload/download) |
| `/omni/search` | Search |
| `/omni/tagging` | Tagging |

The LFT and auth-login Routes use `haproxy.router.openshift.io/rewrite-target: /`
to strip the path prefix, since those services serve static assets or expect
requests at root.

### Inter-service communication

Services discover each other through the Discovery service. Each service
registers two deployments:

- **internal**: Uses Kubernetes service DNS names (e.g. `nucleus-auth:3100`)
  for pod-to-pod communication within the cluster
- **external**: Uses the Route hostname on port 80 with path prefixes, so
  Omniverse desktop clients (Composer, USD Explorer) can connect through the
  Routes

### Storage

All services share a single `ReadWriteOnce` PVC (`nucleus-data`) with `subPath`
mounts to isolate each service's data. This requires all pods to schedule on the
same node. For multi-node setups, switch to a `ReadWriteMany` storage class.

## Customization

Edit `values.yaml` to adjust:
- Container image versions
- Resource requests/limits
- Passwords
- Storage class and size
- NVIDIA reference content (S3-hosted sample assets)
