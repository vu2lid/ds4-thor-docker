# Recipe: ds4 wake-on-request (scale-to-zero)

Run ds4 **only when it's actually being used.** ds4 stays stopped (its ~90 GB free for other GPU
workloads); the **first request wakes it** (blocking until the model is loaded and healthy, ~25–35 s),
and it **stops itself after an idle timeout**, freeing the RAM again. No manual start/stop needed.

This is the practical solution to "a fast ~90 GB model must be resident" — you can't shrink its
footprint, but you *can* make it occupy memory only while in use.

## How it works

```
clients / OpenAI-compatible gateway ──> Traefik (:8000) ──[Sablier middleware]──> ds4:8000
                                                              │ start on request / stop when idle
                                                        Sablier ── docker.sock ── docker
```

- **Traefik** (reverse proxy) owns the public port and routes to ds4. Its **Sablier plugin**
  (blocking strategy) holds the incoming request while the container starts, then forwards it.
- **Sablier** starts/stops the ds4 container via the Docker socket and tracks idle time.
- ds4 has no published port and `restart: no` — its lifecycle is Sablier's.

Tested with `traefik:v3.3` + `sablierapp/sablier:1.8.1`.

## ⚠️ Gotcha that will bite you: Traefik's docker provider

On recent Docker daemons (API ≥ 1.40, e.g. 1.54), Traefik's built-in **docker provider fails**:
`client version 1.24 is too old` — and no routers load. Setting `DOCKER_API_VERSION` on the Traefik
container is **ignored**. The fix used here is to **not use Traefik's docker provider at all** — use
the **file provider** for routing (static YAML), and let **Sablier** keep its own (working) Docker
socket connection for start/stop. Backends are reached by container DNS name on a shared network.

## Prerequisites

- ds4 already runs as a container (from this repo) **with a healthcheck** (the compose here has one —
  Sablier's blocking strategy waits for *healthy*, so the request isn't forwarded before the model loads).
- A **shared external Docker network** that both ds4 and the waker join (referred to as `ai-net` below).
- Reachability by container name on that network.

## 1. Change the ds4 service

In `docker-compose.yml` (this repo), make ds4 Sablier-managed:

```yaml
    container_name: ds4
    restart: "no"          # Sablier owns the lifecycle
    networks: [ai-net]     # shared external network
    # remove the  ports: ["${DS4_PORT:-8000}:8000"]  line — Traefik owns the host port
```
Keep the healthcheck. Recreate it **stopped** so the model doesn't load until woken:
`docker compose up --no-start --force-recreate ds4`

## 2. The waker stack

`waker/docker-compose.yml`:

```yaml
services:
  traefik:
    image: traefik:v3.3
    container_name: waker-traefik
    command:
      - --api.insecure=true                              # dashboard :8080 (bind to localhost only)
      - --entrypoints.web.address=:8000
      - --providers.file.directory=/etc/traefik/dynamic
      - --providers.file.watch=true
      - --experimental.plugins.sablier.moduleName=github.com/sablierapp/sablier
      - --experimental.plugins.sablier.version=v1.8.1
    ports:
      - "8000:8000"
      - "127.0.0.1:8081:8080"
    volumes:
      - ./dynamic:/etc/traefik/dynamic:ro
      - ./plugins-storage:/plugins-storage              # cache the plugin across reboots
    networks: [ai-net]
    restart: unless-stopped

  sablier:
    image: sablierapp/sablier:1.8.1
    container_name: waker-sablier
    command: ["start", "--provider.name=docker"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock       # RW: needed to start/stop containers
    networks: [ai-net]
    restart: unless-stopped

networks:
  ai-net: { external: true }
```

`waker/dynamic/ds4.yml`:

```yaml
http:
  routers:
    ds4:
      entryPoints: [web]
      rule: "PathPrefix(`/`)"
      middlewares: [ds4-sablier]
      service: ds4
  services:
    ds4:
      loadBalancer:
        servers:
          - url: "http://ds4:8000"          # ds4 container on ai-net
  middlewares:
    ds4-sablier:
      plugin:
        sablier:
          sablierUrl: "http://waker-sablier:10000"
          names: "ds4"                       # container Sablier manages
          sessionDuration: "30m"             # idle timeout before stopping ds4
          blocking:
            timeout: "120s"                  # must exceed model load + healthcheck (~25–35 s)
```

Start it: `docker compose -f waker/docker-compose.yml up -d`

## 3. Point your gateway at the waker

If you front ds4 with an OpenAI-compatible gateway (LiteLLM, etc.), change its ds4 `api_base` to the
Traefik container: `http://waker-traefik:8000/v1`. Direct clients hit the host `:8000`.

## Key parameters

- **`blocking.timeout` ≥ model load + healthcheck** — ~120 s is safe (load ~25 s from NVMe; the
  block holds until ds4 reports *healthy*).
- **`sessionDuration`** — idle time before stop. Every request resets it. 30 m is a reasonable default.
- Set client/gateway request timeouts ≥ 60 s so the first (cold) request isn't dropped.

## Behavior

- **First request after idle:** blocks ~25–35 s (wake + load), then streams normally. Subsequent
  requests are instant.
- **Idle:** after `sessionDuration` with no requests, ds4 stops → its ~90 GB is reclaimable by other
  GPU apps (see the README's *Memory footprint & coexistence* — `free` will still look high; the
  memory is reclaimed on demand).
- **Reboot:** Traefik + Sablier auto-start (plugin cached to `plugins-storage/`); ds4 stays down
  (`restart: no`) until the first request wakes it.
- **Manual override:** `docker start ds4` (pre-warm), `docker stop ds4` (force-free). Do **not**
  `docker compose down` ds4 — that removes the container Sablier needs to wake; use `stop`.

## Security note

Sablier needs **read-write** access to `/var/run/docker.sock` (to start/stop containers) — that's
root-equivalent on the host. Fine for a single-user homelab; lock it down (or use a socket proxy
scoped to container start/stop) if the box is shared.

## Rollback

Stop the waker (`docker compose -f waker/docker-compose.yml down`), restore ds4's `ports:` and
`restart: unless-stopped`, and point your gateway back at `http://ds4:8000/v1`.
