# Homepage Gotchas, Edge Cases & Battle-Tested Fixes

This document compiles operational gotchas and edge cases discovered when deploying and integrating **Homepage** (`ghcr.io/gethomepage/homepage:latest`) on Raspberry Pi 5 (`192.168.4.5`) behind native Caddy.

---

## 1. Next.js 16 Host Header Validation (`400 Bad Request`)

### Symptom
Accessing `http://192.168.4.5:3001` or `http://192.168.4.5` returns `HTTP/1.1 400 Bad Request` with payload:
```json
{"error":"Host validation failed. See logs for more details."}
```
Container logs show:
```text
error: Host validation failed for: 192.168.4.5:3001. Hint: Set the HOMEPAGE_ALLOWED_HOSTS environment variable to allow requests from this host / port.
error: Host validation failed for: 192.168.4.5. Hint: Set the HOMEPAGE_ALLOWED_HOSTS environment variable to allow requests from this host / port.
```

### Root Cause
Homepage builds on modern Next.js (v16+). Next.js enforces host header validation to mitigate DNS rebinding and cross-site request attacks. By default, requests carrying host headers other than `localhost` or `127.0.0.1` are rejected unless explicitly allowed.

### Fix
Define `HOMEPAGE_ALLOWED_HOSTS` in `compose/192.168.4.5/homepage/docker-compose.yml`:
```yaml
environment:
  - HOMEPAGE_ALLOWED_HOSTS=192.168.4.5,192.168.4.5:3001,localhost,localhost:3001,127.0.0.1,127.0.0.1:3001,*.vvvega.com,*.local,*.home,*.lan,*
```

---

## 2. Glances Widget: `TypeError: Cannot read properties of undefined (reading 'match')`

### Symptom
When the dashboard loads in the browser, all Glances cards display a red error banner:
```text
Something went wrong: TypeError: Cannot read properties of undefined (reading 'match')
```

### Root Cause
In Homepage's Glances client component (`/app/src/widgets/glances/component.jsx`):
```javascript
export default function Component({ service }) {
  const { widget } = service;

  if (widget.metric === "info") { return <Info service={service} />; }
  if (widget.metric === "memory") { return <Memory service={service} />; }
  if (widget.metric === "process") { return <Process service={service} />; }
  if (widget.metric === "containers") { return <Containers service={service} />; }
  if (widget.metric === "cpu") { return <Cpu service={service} />; }

  if (widget.metric.match(/^network:/)) { return <Net service={service} />; }
  // ...
}
```
If `metric:` is omitted from the service definition in `services.yaml`, `widget.metric` evaluates to `undefined`. When execution reaches line 35 (`widget.metric.match(...)`), JavaScript attempts to execute `.match()` on `undefined`, immediately throwing this TypeError on the frontend.

### Fix
Always specify an explicit `metric` in `services.yaml`. For system CPU tracking:
```yaml
widget:
  type: glances
  url: http://192.168.4.5:61208
  version: 4
  metric: cpu
```

---

## 3. Quicklinks: `TypeError: Failed to construct 'URL': Invalid URL`

### Symptom
The bookmarks / quicklinks section fails to render and shows:
```text
Something went wrong: TypeError: Failed to construct 'URL': Invalid URL
```

### Root Cause
In `bookmarks.yaml`, putting properties on separate dashed list lines creates two separate dictionary items in an array:
```yaml
# ❌ INCORRECT:
- Homelab Quicklinks:
    - GitHub:
        - icon: github.png
        - href: https://github.com/
```
In YAML, `- icon:` is item 0, and `- href:` is item 1. The first item has no `href` property. Homepage attempts `new URL(bookmark.href)`, which executes `new URL(undefined)`, throwing `Invalid URL`.

### Fix
Group all properties under a single dictionary item:
```yaml
# ✅ CORRECT:
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

---

## 4. Docker Socket Permission Denied (`EACCES /var/run/docker.sock`)

### Symptom
Homepage logs report continuous errors:
```text
error: <dockerStatuses> Error: connect EACCES /var/run/docker.sock
error: <service-helpers> Error getting services from Docker server 'local-docker': Error: connect EACCES /var/run/docker.sock
```
Docker container status badges remain grey or fail to report running status.

### Root Cause
On Debian/Pi OS, `/var/run/docker.sock` has group ownership `root:docker` with mode `0660` (`srw-rw----`). The host's `docker` group has GID `990`.
Homepage starts container processes as `node` (UID `1000`). If `PGID=1000` is configured, `node` only belongs to GID 1000 and is denied permission to read or write to `/var/run/docker.sock`.

### Fix
In `docker-compose.yml`, set `PGID=990`:
```yaml
environment:
  - PUID=1000
  - PGID=990
```
Homepage's entrypoint script drops privileges via `su-exec 1000:990`, granting the node process group access to the docker socket while preserving UID 1000 ownership on `/app/config`.

---

## 5. Caddy Ingress & Automatic Port 80 Clean Routing

### Symptom
Users do not want to memorize or type port `:3001` every time they access the dashboard. Accessing `http://192.168.4.5/` redirects to HTTPS (`https://192.168.4.5/`) which fails with SSL certificate alerts (`tlsv1 alert internal error`) because no public certificate covers the local private IP.

### Root Cause
By default, Caddy issues automatic HTTPS redirects for unmapped port 80 traffic unless an explicit HTTP site block is declared.

### Fix
In `files/caddy/Caddyfile`, add an explicit `http://192.168.4.5` site block:
```caddy
http://192.168.4.5 {
	reverse_proxy 127.0.0.1:3001
}
```
This tells Caddy to terminate standard port 80 HTTP for the local host and proxy directly to Homepage at `127.0.0.1:3001`, without triggering any HTTPS redirects.

---

## 6. Glances API Major Version Compatibility (`version: 4`)

### Symptom
Homepage fails to fetch metrics from modern Glances instances, returning empty payloads or API errors.

### Root Cause
Glances updated its REST API from version 3 to version 4 in recent releases (changing paths from `/api/3/*` to `/api/4/*`). Homepage defaults to version 3 if unspecified.

### Fix
Always specify `version: 4` in the widget block:
```yaml
widget:
  type: glances
  url: http://192.168.4.5:61208
  version: 4
  metric: cpu
```
Check API responsiveness manually:
```bash
curl -s http://192.168.4.5:61208/api/4/quicklook
```
