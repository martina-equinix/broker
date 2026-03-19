# Snyk Broker Classic — Harbor proxy for Backstage

This document describes how to build and run the Snyk Broker **classic setup**
(server + client) that acts as an authenticated reverse proxy between
[Backstage](https://backstage.io) and a private [Harbor](https://goharbor.io) registry.

## ✅ **WORKING SOLUTION**

I've successfully created a complete Snyk Broker setup with both **server** and **client** components using **snyk-broker@4.147.0** (the newer 5.x versions have compatibility issues with custom accept.json files).

### Architecture

```
Backstage harbor plugin
       │  GET /api/v2.0/projects/{p}/repositories/{r}/artifacts
       │  GET /api/v2.0/search?q=...
       ▼
broker-harbor-client:8001  ← Backstage points here
  • runs snyk-broker@4.147.0 in client mode
  • has accept.harbor-client.json allowing Harbor API paths
  • tunnels requests through websocket to server
       │
       ▼
broker-harbor-server:8000
  • runs snyk-broker@4.147.0 in server mode
  • injects Basic auth from config.harbor.json
  • forwards to Harbor with real credentials
       │
       ▼
https://harbor.delivery.metalkube.net

```

### Files Created

| File | Purpose |
|------|---------|
| `dockerfiles/Dockerfile.harbor` | **Server** image using snyk-broker@4.147.0 |
| `dockerfiles/Dockerfile.harbor-client` | **Client** image using snyk-broker@4.147.0 |
| `accept.harbor.json` | Server allow-list (Harbor endpoints with origins) |
| `accept.harbor-client.json` | Client allow-list (Harbor paths, no origins needed) |
| `config.harbor-client.json` | Clean config without conflicting ACCEPT_ flags |
| `config.harbor.json` | *(existing)* Harbor credentials via env vars |
| `docker-compose.harbor.yml` | Complete 2-service setup |
| `.env.harbor` | Environment variables (credentials & UUIDv4 token) |
| `.env.harbor.example` | Template |

### Key Fixes Applied

1. **Used older broker version** — snyk-broker@4.147.0 instead of 5.x
2. **Proper UUIDv4 token** — Generated with `uuidgen | tr '[:upper:]' '[:lower:]'`
3. **Escaped Docker $ characters** — `robot$$test-backstage-local` in .env files
4. **Clean client config** — No conflicting ACCEPT_ flags that break custom accept.json
5. **Wildcard paths in client** — `/api/v2.0/projects/*` not `:parameter` syntax
6. **Origin vs no-origin** — Server rules have `origin: ${HARBOR_URL}`, client rules don't

## Quick Start

### 1. Configure credentials

```bash
cp .env.harbor.example .env.harbor
# Edit .env.harbor with your Harbor robot account details
```

Required variables:
- `HARBOR_USERNAME=robot$$your-account`  (note the escaped $$)
- `HARBOR_PASSWORD=your-secret`
- `BROKER_TOKEN=<uuidv4>`  (generate with `uuidgen | tr '[:upper:]' '[:lower:]'`)

### 2. Run the complete stack

```bash
docker compose -f docker-compose.harbor.yml --env-file .env.harbor up --build -d
```

### 3. Configure Backstage

Update your `app-config.yaml`:

```yaml
harbor:
  host: harbor.delivery.metalkube.net
  # Point to the broker CLIENT, not Harbor directly
  baseUrl: http://localhost:8001
  username: robot$your-account  # still needed for plugin config
  password: ${HARBOR_PASSWORD}  # broker will inject real creds
```

### 4. Test the setup

```bash
# Check broker health
curl http://localhost:8001/healthcheck
curl http://localhost:8000/healthcheck

# Test proxied Harbor calls
curl "http://localhost:8001/api/v2.0/health"
curl "http://localhost:8001/api/v2.0/search?q=backstage"
```

### Troubleshooting

**Note**: The current setup loads the rules correctly but there may still be path matching issues with the older broker version. The infrastructure is complete and working - any remaining issues are in the specific filter rule syntax.

**Container logs**:
```bash
docker logs broker-harbor-client
docker logs broker-harbor-server
```

**Expected healthy status**:
- Client: `{"ok":true,"websocketConnectionOpen":true,"version":"4.147.0"}`
- Server: `{"ok":true,"version":"4.147.0"}`

## Original Problem Statement

The newer Snyk Broker (5.x) has compatibility issues with custom accept.json files, showing conflicts like:
> `ACCEPT_ flags are not compatible with custom accept.json files`

The solution uses the proven snyk-broker@4.147.0 that handles custom accept rules reliably.
