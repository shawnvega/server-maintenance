---
name: setup-homepage
description: >-
  Use this skill when deploying, configuring, troubleshooting, or customizing the Homepage
  dashboard container on Raspberry Pi 5 (192.168.4.5), integrating with Caddy reverse proxy,
  or configuring cluster monitoring and service widgets.
---

# Homepage Dashboard Setup & Management

This skill guides the provisioning, lifecycle management, verification, and troubleshooting of the **Homepage** dashboard (`ghcr.io/gethomepage/homepage:latest`) on `192.168.4.5` integrated with the native **Caddy reverse proxy**.

For in-depth explanations and code fixes for specific errors, refer to:
* **[references/gotchas.md](references/gotchas.md)**: Deep dive into Next.js host header protection, Glances undefined regex errors, bookmark YAML schemas, and Docker socket permissions.

---

## Quick Triage Decision Matrix

When encountering issues with the dashboard, locate the symptom below for the instant verified fix:

| Symptom / Error | Root Cause | Instant Resolution |
|---|---|---|
| HTTP 400 Bad Request: `Host validation failed` | Next.js 16 host header protection blocks unexpected Host headers | Ensure `HOMEPAGE_ALLOWED_HOSTS` includes `192.168.4.5`, `192.168.4.5:3001`, `localhost`, `*` in `compose/192.168.4.5/homepage/docker-compose.yml` |
| Monitoring card crash: `TypeError: Cannot read properties of undefined (reading 'match')` | Glances component evaluates `widget.metric.match(...)` which throws when `metric:` is omitted | Explicitly add `metric: cpu` (or `memory`, `containers`) in `services.yaml` |
| Quicklinks crash: `TypeError: Failed to construct 'URL': Invalid URL` | Separate dashed lines in `bookmarks.yaml` split properties into separate list items without `href` | Group all properties under a single dictionary item with `abbr:`, `href:`, and `icon:` |
| Container logs report `EACCES /var/run/docker.sock` | Container node process lacks host `docker` group membership (host GID 990) | Set `PGID=990` in `compose/192.168.4.5/homepage/docker-compose.yml` |
| Glances metrics empty or failing | Glances v4 API path changes | Add `version: 4` to widget definitions in `services.yaml` |
| Port `:3000` conflict on Pi 5 | Semaphore UI already binds port 3000 | Map Homepage host port to `3001:3000` in `docker-compose.yml` |

---

## 1. Quick Reference & Architecture

* **Host Machine (`192.168.4.5`)**:
  * OS: Debian GNU/Linux 12 (bookworm) / Raspberry Pi OS aarch64.
  * Hardware: Raspberry Pi 5 Model B (4 cores), 8GB RAM.
  * Co-located workloads: Semaphore UI (`:3000`), Immich ML (`:3003`), Glances (`:61208`), and native Caddy reverse proxy (`:80`, `:443`).
* **Ingress & Networking**:
  * **Direct Port**: `http://192.168.4.5:3001`
  * **Caddy Reverse Proxy**: Clean URL `http://192.168.4.5` (port 80). Caddy terminates standard HTTP and proxies to `127.0.0.1:3001` without SSL redirect issues on LAN.
* **Storage & Configuration Paths**:
  * Git Source: `compose/192.168.4.5/homepage/`
  * Host Runtime: `/home/shawn/docker/homepage/`
  * Config Directory: `/home/shawn/docker/homepage/config/`
* **Docker Socket Integration**:
  * Volume: `/var/run/docker.sock:/var/run/docker.sock:ro`
  * Security Context: `PUID=1000`, `PGID=990` (`docker` group on Pi OS).

---

## 2. Configuration Files & Schemas

All dashboard configuration lives in `compose/192.168.4.5/homepage/config/`:

### `settings.yaml`
Controls page layout, theme, header style, and layout columns:
```yaml
---
title: Homelab
favicon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/server.png
theme: dark
color: slate

headerStyle: clean

layout:
  Core Infrastructure:
    style: row
    columns: 4
  Automation & AI:
    style: row
    columns: 4
  Media & Storage:
    style: row
    columns: 4
  Monitoring:
    style: row
    columns: 3
```

### `services.yaml`
Declares service tiles, grouping, container health tracking, and metrics:
```yaml
---
- Core Infrastructure:
    - Semaphore:
        icon: semaphore.png
        href: http://192.168.4.5:3000
        description: Ansible Automation Controller (Pi 5)
        server: local-docker
        container: semaphore
    - PiKVM:
        icon: pikvm.png
        href: https://192.168.4.66
        description: Remote Hardware Console (Arch ARM)
        ping: 192.168.4.66
    - Cockpit:
        icon: cockpit.png
        href: https://192.168.4.19:9090
        description: Fedora Web Admin Console (Workstation)
        ping: 192.168.4.19
    - Caddy Proxy:
        icon: caddy.png
        href: http://192.168.4.5
        description: Native Reverse Proxy & TLS (Pi 5)

- Media & Storage:
    - OpenMediaVault:
        icon: openmediavault.png
        href: http://192.168.4.4
        description: Network-Attached Storage & Web Admin (Pi 4)
        ping: 192.168.4.4
    - Immich:
        icon: immich.png
        href: https://immich.vvvega.com
        description: Photo & Video Management (Pi 4)
    - Jellyfin:
        icon: jellyfin.png
        href: http://192.168.4.4:8096
        description: Media Streaming Server (Pi 4)
    - Syncthing:
        icon: syncthing.png
        href: http://192.168.4.4:8384
        description: Peer-to-Peer File Sync (Pi 4)

- Monitoring:
    - Glances Pi 5:
        icon: glances.png
        href: http://192.168.4.5:61208
        description: Pi 5 System & Docker Metrics
        widget:
          type: glances
          url: http://192.168.4.5:61208
          version: 4
          metric: cpu
    - Glances Chromebook:
        icon: glances.png
        href: http://192.168.4.18:61208
        description: Chromebook & Btrfs Metrics (Ubuntu)
        widget:
          type: glances
          url: http://192.168.4.18:61208
          version: 4
          metric: cpu
    - Glances Plant Monitor:
        icon: glances.png
        href: http://192.168.4.11:61208
        description: E-Ink Display & System Metrics (Pi 2)
        widget:
          type: glances
          url: http://192.168.4.11:61208
          version: 4
          metric: cpu
    - Frigate NVR:
        icon: frigate.png
        href: https://192.168.4.19:8971
        description: Camera Object Detection (Fedora)
        ping: 192.168.4.19
```

### `widgets.yaml`
Configures the global top bar information widgets:
```yaml
---
- search:
    provider: duckduckgo
    target: _blank

- resources:
    cpu: true
    memory: true
    disk: /
    cputemp: true
```

### `bookmarks.yaml`
Configures static quicklinks. Always keep properties nested in the same dictionary:
```yaml
---
- Homelab Quicklinks:
    - GitHub:
        - abbr: GH
          href: https://github.com/
          icon: github.png
    - Router Admin:
        - abbr: RT
          href: http://192.168.4.1/
          icon: router.png
```

### `docker.yaml`
Configures local container engine connections:
```yaml
---
local-docker:
  socket: /var/run/docker.sock
```

---

## 3. Operational Workflows & Commands

### Deploy / Update Dashboard Configuration
After editing any file in `compose/192.168.4.5/homepage/config/` or `docker-compose.yml`:
```bash
./run.sh homepage
```
This runs `deploy_homepage.yml`, which:
1. Validates host system loadavg is under threshold (`6.0`).
2. Syncs `docker-compose.yml` to `/home/shawn/docker/homepage/`.
3. Recursively syncs `config/` to `/home/shawn/docker/homepage/config/`.
4. Recreates and starts the container via `docker compose up -d --remove-orphans`.

### Caddy Ingress Maintenance
If updating ingress rules or domain mappings:
```bash
./run.sh caddy
```
Caddy automatically validates `/etc/caddy/Caddyfile` before performing a zero-downtime `systemctl reload caddy`.

### Automated Verification
Run the integrated test script to verify HTTP status codes, reverse proxy forwarding, Docker socket permissions, and Glances connectivity:
```bash
.agents/skills/setup-homepage/scripts/verify_homepage.sh
```

---

## 4. Key Rules for Agents Modifying Homepage

1. **Always use `./run.sh homepage`**: Never run raw ad-hoc `docker compose` commands directly on the host if you can avoid it; the playbook guarantees directory synchronization.
2. **Never omit `metric:` on Glances widgets**: Homepage's React component expects a non-null string and will crash with `TypeError` if undefined.
3. **Keep `PGID=990`**: Do not revert `PGID` to 1000; node needs GID 990 to communicate with `/var/run/docker.sock`.
4. **Maintain `HOMEPAGE_ALLOWED_HOSTS`**: When introducing new local domain names (e.g. `*.home.arpa`), append them to `HOMEPAGE_ALLOWED_HOSTS` in `docker-compose.yml`.
5. **Run Syntax Checks**: Always run `.venv/bin/ansible-playbook deploy_homepage.yml --syntax-check` before committing playbook updates.
