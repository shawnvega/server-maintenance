# Homepage Dashboard: Architecture, Configuration & Troubleshooting

This document details the configuration, Caddy reverse proxy integration, widget schemas, and troubleshooting runbooks for the **Homepage** dashboard (`ghcr.io/gethomepage/homepage:latest`) running on Raspberry Pi 5 (`192.168.4.5`).

---

## 1. Architecture & Networking

* **Host Machine (`192.168.4.5`)**:
  * OS: Debian GNU/Linux 12 (bookworm) / Raspberry Pi OS aarch64.
  * Direct Container Port: `3001` (mapped as `3001:3000` to avoid conflicts with Semaphore UI on port 3000).
* **Reverse Proxy Ingress**:
  * Clean URL: `http://192.168.4.5` (port 80).
  * Native Caddy reverse proxy terminates port 80 and reverse proxies upstream to `127.0.0.1:3001`.
* **Repository & Host Paths**:
  * Git Source: `compose/192.168.4.5/homepage/`
  * Host Runtime: `/home/shawn/docker/homepage/`
  * Configuration: `/home/shawn/docker/homepage/config/`
* **Docker Socket Integration**:
  * Volume Mount: `/var/run/docker.sock:/var/run/docker.sock:ro`
  * Security Context: `PUID=1000`, `PGID=990` (`docker` group GID on Pi OS).

### Management Commands
```bash
# Deploy / update Homepage configuration
./run.sh homepage

# Inspect Homepage logs
ssh shawn@192.168.4.5 'docker logs -f homepage --tail 50'
```

---

## 2. Common Errors & Troubleshooting Runbooks

### 1. Host Validation Failed (`400 Bad Request`)
* **Symptom**: Accessing `http://192.168.4.5:3001` or `http://192.168.4.5` returns HTTP 400 with `{"error":"Host validation failed. See logs for more details."}`.
* **Root Cause**: Next.js 16 host header protection rejects requests with unlisted Host headers.
* **Fix**: Ensure `HOMEPAGE_ALLOWED_HOSTS` is defined in `compose/192.168.4.5/homepage/docker-compose.yml`:
  ```yaml
  environment:
    - HOMEPAGE_ALLOWED_HOSTS=192.168.4.5,192.168.4.5:3001,localhost,localhost:3001,127.0.0.1,127.0.0.1:3001,*.vvvega.com,*.local,*.home,*.lan,*
  ```
  Then redeploy via `./run.sh homepage`.

### 2. Glances Widget: `TypeError: Cannot read properties of undefined (reading 'match')`
* **Symptom**: Glances monitoring cards crash on the frontend with `TypeError: Cannot read properties of undefined (reading 'match')`.
* **Root Cause**: Homepage's Glances component evaluates `widget.metric.match(...)`. If `metric:` is omitted in `services.yaml`, `widget.metric` is `undefined`, crashing client-side rendering.
* **Fix**: Always specify `metric: cpu` (or `memory`, `containers`, `process`) in `services.yaml`:
  ```yaml
  widget:
    type: glances
    url: http://192.168.4.5:61208
    version: 4
    metric: cpu
  ```

### 3. Bookmarks: `TypeError: Failed to construct 'URL': Invalid URL`
* **Symptom**: Quicklinks section crashes with `TypeError: Failed to construct 'URL': Invalid URL`.
* **Root Cause**: In YAML, placing `- icon:` and `- href:` on separate dashed lines creates two separate list items; the first item has no `href`, resulting in `new URL(undefined)`.
* **Fix**: Group all bookmark properties under a single dictionary item:
  ```yaml
  - Homelab Quicklinks:
      - GitHub:
          - abbr: GH
            href: https://github.com/
            icon: github.png
  ```

### 4. Docker Socket Permission Denied: `EACCES /var/run/docker.sock`
* **Symptom**: Container logs report `error: <dockerStatuses> Error: connect EACCES /var/run/docker.sock`.
* **Root Cause**: On Debian/Pi OS, `/var/run/docker.sock` has group ownership `docker` (GID `990`). If Homepage runs with `PGID=1000`, it cannot read the socket.
* **Fix**: Set `PGID=990` in `compose/192.168.4.5/homepage/docker-compose.yml`.

### 5. Frigate NVR Connection Refused (`http://...:5000`)
* **Symptom**: Clicking the Frigate tile in Homepage fails with `ERR_CONNECTION_REFUSED` or curl returns `Failed to connect port 5000: Connection refused`.
* **Root Cause**: Frigate 0.14+ deprecates unauthenticated port 5000 ingress. The host container compose maps host port `8971` with HTTPS TLS (`0.0.0.0:8971->8971/tcp`), leaving internal port `5000` unexposed.
* **Fix**: Configure `href: https://192.168.4.19:8971` and `ping: 192.168.4.19` in `services.yaml`.

### 6. Container Failed to Start: `RWLayer of container ... is unexpectedly nil`
* **Symptom**: Starting or restarting an existing Docker container fails with `Error response from daemon: RWLayer of container ... is unexpectedly nil`.
* **Root Cause**: Occurs when Docker daemon restarts, root or storage paths migrate, or overlay2/btrfs mount graph driver cache desynchronizes from container metadata.
* **Fix**: Force recreate the container stack cleanly:
  ```bash
  docker compose -f /home/shawn/docker/<service>/compose.yml up -d --force-recreate
  ```
