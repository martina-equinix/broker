# Snyk Broker Classic — Harbor & ArgoCD proxy for Backstage

Snyk Broker acts as an authenticated reverse-proxy between **Backstage** and
private backends (Harbor, ArgoCD) that are not directly reachable from the
cluster where Backstage runs.

```
Backstage  ──► broker-server ──► (WebSocket) ──► broker-client ──► Harbor / ArgoCD
              (METAL cluster)                      (GEN network)
```

The broker-client dials **outbound** from GEN to METAL, so no inbound firewall
rules are needed on the GEN side.

---

## Part 1 — Local POC with Docker Compose

Use this to verify the full flow on your laptop before touching any cluster.

### Architecture (local)

```
                  Docker network (single host)
  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  Backstage (localhost:3000/7007)                         │
  │       │                                                  │
  │       │  http://localhost:7341/broker/<TOKEN>/...        │
  │       ▼                                                  │
  │  broker-server:7341          ← shared server             │
  │       │  WebSocket                                       │
  │       ├──► broker-harbor-client:8001 ──► Harbor (HTTPS)  │
  │       └──► broker-argocd-client:8002 ──► ArgoCD (HTTPS)  │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
```

### Files

| File | Purpose |
|------|---------|
| `docker-compose.harbor.yml` | All-in-one local POC (server + both clients) |
| `.env.harbor.example` | Template — copy to `.env.harbor` and fill in |
| `.env.harbor` | Your local credentials (**gitignored**) |
| `dockerfiles/Dockerfile.server` | Broker server image (`snyk-broker@4.147.0`) |
| `dockerfiles/Dockerfile.client` | Generic broker client image |
| `accept.server.json` | Server allow-list (all backends) |
| `accept.harbor-client.json` | Harbor client allow-list |
| `accept.argocd-client.json` | ArgoCD client allow-list |

### Quick start

```bash
# 1. Copy and fill in the env file
cp .env.harbor.example .env.harbor
#    Set HARBOR_URL, HARBOR_USERNAME, HARBOR_PASSWORD, ARGOCD_URL,
#    and generate two tokens:
#      HARBOR_BROKER_TOKEN=$(uuidgen | tr '[:upper:]' '[:lower:]')
#      ARGOCD_BROKER_TOKEN=$(uuidgen | tr '[:upper:]' '[:lower:]')

# 2. Start all three containers
docker compose -f docker-compose.harbor.yml --env-file .env.harbor up --build -d

# 3. Check health
curl http://localhost:7341/healthcheck        # server
curl http://localhost:8001/healthcheck        # harbor client
curl http://localhost:8002/healthcheck        # argocd client
```

### Backstage config (`app-config.local.yaml`)

```yaml
harbor:
  host: localhost:7341
  baseUrl: http://localhost:7341/broker/<HARBOR_BROKER_TOKEN>/
  username: ${HARBOR_USERNAME}
  password: ${HARBOR_TOKEN}

argocd:
  revisionsToLoad: 3
  appLocatorMethods:
    - type: 'config'
      instances:
        - name: argocd-staging
          url: http://localhost:7341/broker/<ARGOCD_BROKER_TOKEN>
          token: ${ARGOCD_TOKEN}
```

### Test commands

```bash
# Harbor — search images
curl -s "http://localhost:7341/broker/${HARBOR_BROKER_TOKEN}/api/v2.0/search?q=backstage" | jq .

# Harbor — list projects
curl -s "http://localhost:7341/broker/${HARBOR_BROKER_TOKEN}/api/v2.0/projects" | jq .

# ArgoCD — list applications
curl -s "http://localhost:7341/broker/${ARGOCD_BROKER_TOKEN}/api/v1/applications" | jq .

# ArgoCD — server version
curl -s "http://localhost:7341/broker/${ARGOCD_BROKER_TOKEN}/api/v1/version" | jq .
```

### Tear down

```bash
docker compose -f docker-compose.harbor.yml --env-file .env.harbor down
```

---

## Part 2 — Production deployment with Helm

> **Docker Compose is not used in production.**
> Each component is deployed as a separate Helm release in its own cluster.

### Topology

```
  ┌──────────────── METAL cluster ─────────────────────────────┐
  │                                                            │
  │   Backstage (Deployment)                                   │
  │        │  http://broker-server:7341/broker/<TOKEN>/...     │
  │        ▼                                                   │
  │   broker-server (Deployment + ClusterIP Service)           │
  │        ▲  WebSocket (outbound from GEN)                    │
  │        │  exposed via Ingress or internal LoadBalancer     │
  └────────┼───────────────────────────────────────────────────┘
           │
  ┌────────┼───────── GEN cluster ──────────────────────────────┐
  │        │                                                    │
  │   broker-harbor-client (Deployment)  ──► Harbor            │
  │   broker-argocd-client (Deployment)  ──► ArgoCD            │
  │                                                            │
  └────────────────────────────────────────────────────────────┘
```

### Helm chart options

The upstream Snyk Broker does not ship an official Helm chart.
The recommended approach is to write a thin in-house chart using the Docker
images already built by `dockerfiles/Dockerfile.server` and
`dockerfiles/Dockerfile.client`.

#### Suggested chart layout

```
charts/broker/
├── Chart.yaml
├── values.yaml
├── values-metal.yaml            # server overrides (METAL cluster)
├── values-gen.yaml              # client overrides (GEN cluster)
└── templates/
    ├── deployment-server.yaml       # broker-server
    ├── service-server.yaml          # ClusterIP — Backstage → server
    ├── ingress-server.yaml          # exposes :7341 to GEN (restricted)
    ├── deployment-client.yaml       # one Deployment per client (loop)
    ├── configmap-accept.yaml        # accept.server.json + accept.*.json
    └── externalsecret.yaml          # or secret.yaml if not using ESO
```

Deploy the server in METAL:

```bash
helm upgrade --install broker-server charts/broker \
  -f charts/broker/values-metal.yaml \
  --set server.enabled=true \
  --set clients.enabled=false \
  --namespace backstage
```

Deploy the clients in GEN:

```bash
helm upgrade --install broker-clients charts/broker \
  -f charts/broker/values-gen.yaml \
  --set server.enabled=false \
  --set clients.enabled=true \
  --namespace broker
```

### Security in Kubernetes

| Concern | Recommendation |
|---------|----------------|
| **Token storage** | Store `HARBOR_BROKER_TOKEN`, `ARGOCD_BROKER_TOKEN`, and backend credentials in Kubernetes `Secrets` (or an external secret manager like Vault / ESO). Never commit them to Git or put them in `values.yaml`. |
| **Network exposure** | The broker server only needs to be reachable from GEN. Use an `Ingress` with `nginx.ingress.kubernetes.io/allowlist-source-range` limited to the GEN CIDR, or an internal-only `LoadBalancer` (cloud annotation). |
| **Transport encryption** | Terminate TLS at the Ingress level (cert-manager + Let's Encrypt or your corporate CA). The WebSocket from the broker client to the server then travels over WSS (WebSocket over HTTPS). |
| **Token is a routing key, not authentication** | The broker token is used to route requests to the right client — the server performs no cryptographic check. The real protection is network-level: if only GEN can reach the broker-server Ingress, unauthorized clients cannot register. |
| **NetworkPolicy (METAL)** | Restrict the broker-server pod so it only accepts traffic from the Ingress controller pod (GEN clients) and the Backstage pod. |
| **Image registry** | Push the built images to your internal Harbor and reference them in Helm values — do not pull from Docker Hub in production. |

### Secrets layout (example with ESO + Vault)

**METAL cluster** — broker-server (needs the token list so it can validate routing):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: broker-tokens
  namespace: backstage
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: broker-tokens
  data:
    - secretKey: HARBOR_BROKER_TOKEN
      remoteRef: { key: backstage/broker, property: harbor_token }
    - secretKey: ARGOCD_BROKER_TOKEN
      remoteRef: { key: backstage/broker, property: argocd_token }
```

**GEN cluster** — broker-clients (same tokens + backend credentials):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: broker-client-harbor
  namespace: broker
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: broker-client-harbor
  data:
    - secretKey: HARBOR_BROKER_TOKEN
      remoteRef: { key: backstage/broker, property: harbor_token }
    - secretKey: BACKEND_URL
      remoteRef: { key: backstage/broker, property: harbor_url }
    - secretKey: HARBOR_PASSWORD
      remoteRef: { key: backstage/broker, property: harbor_password }
```

### Helm values sketch

```yaml
# values.yaml skeleton

server:
  enabled: true
  image:
    repository: harbor.delivery.metalkube.net/backstage/broker-server
    tag: "4.147.0"
  port: 7341
  existingSecret: broker-tokens   # contains HARBOR_BROKER_TOKEN, ARGOCD_BROKER_TOKEN
  ingress:
    enabled: true
    className: nginx
    host: broker.metal.internal.example.com
    annotations:
      # Restrict to GEN CIDR only
      nginx.ingress.kubernetes.io/allowlist-source-range: "10.x.x.0/24"

clients:
  enabled: true
  harbor:
    image:
      repository: harbor.delivery.metalkube.net/backstage/broker-client
      tag: "4.147.0"
    port: 8001
    brokerServerUrl: "https://broker.metal.internal.example.com"
    acceptFile: /home/node/accept.harbor-client.json
    existingSecret: broker-client-harbor   # HARBOR_BROKER_TOKEN, BACKEND_URL, HARBOR_PASSWORD

  argocd:
    image:
      repository: harbor.delivery.metalkube.net/backstage/broker-client
      tag: "4.147.0"
    port: 8002
    brokerServerUrl: "https://broker.metal.internal.example.com"
    acceptFile: /home/node/accept.argocd-client.json
    existingSecret: broker-client-argocd   # ARGOCD_BROKER_TOKEN, BACKEND_URL, ARGOCD_TOKEN
```

---

## Troubleshooting

```bash
# Container logs (local POC)
docker logs broker-server
docker logs broker-harbor-client
docker logs broker-argocd-client
```

Expected healthy responses:

```json
// Server
{"ok":true,"version":"4.147.0"}

// Client
{"ok":true,"websocketConnectionOpen":true,"version":"4.147.0"}
```

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `websocketConnectionOpen: false` | Client can't reach the server | Check `BROKER_SERVER_URL` and network connectivity |
| `401 Unauthorized` from Harbor/ArgoCD | Wrong credentials | Check `HARBOR_PASSWORD` / `ARGOCD_TOKEN` in `.env.harbor` |
| `ACCEPT_ flags … not compatible` | Using broker v5.x | Image is pinned to `snyk-broker@4.147.0` — do not upgrade |
| `robot$` username stripped | `$` not escaped in `.env` | Use `$$` in `.env` files: `robot$$test-backstage-local` |
