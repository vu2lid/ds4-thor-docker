# ds4-thor-docker

Container packaging for **[ds4](https://github.com/antirez/ds4)** (DwarfStar / DeepSeek‑V4‑Flash)
on NVIDIA aarch64 CUDA boxes with unified memory — built and tested on a **Jetson AGX Thor
(compute capability 11.0 / `sm_110`, CUDA 13, Ubuntu 24.04)**. It should also work on a
**DGX Spark (GB10 / `sm_121`)** by setting `DS4_CUDA_ARCH` (untested here — reports welcome).

This repo provides **only the Dockerfile, compose, build script, and docs**. It does **not**
include ds4 or any model weights — you clone/build ds4 and download the model yourself.

> Not affiliated with the upstream project. ds4 is by the ds4.c authors (MIT):
> https://github.com/antirez/ds4

## Why containerize it?

- **Consistent runtime** across ds4/CUDA updates and reboots via the standard Docker/Compose lifecycle.
- **Stable endpoint** — OpenAI‑compatible API on `:8000` for any compatible client (e.g. VS Code agents, Open WebUI, LiteLLM).
- **Persistent disk KV cache** — see below.
- **Pinned build provenance** via image labels, so you can tell "ds4 regression" from
  "CUDA/container regression".

## How it works

- Thin `ubuntu:24.04` runtime image; ds4 binaries are **prebuilt on the host** (`build.sh`) and
  copied in — no CUDA toolkit inside the image.
- The **host CUDA runtime is bind‑mounted** at `/usr/local/cuda` (read‑only), so the image always
  matches your host toolkit and stays ~200 MB. `libcuda.so` is injected by the NVIDIA container runtime.
- The **model is bind‑mounted** read‑only; **disk KV checkpoints** live on a host volume.

## Prerequisites

- Docker + the **NVIDIA container runtime** (`runtime: nvidia`; on Jetson this is the default).
- **CUDA toolkit** on the host (CUDA 13 for Thor). `nvcc` must be on `PATH` to build.
- A local clone of **[antirez/ds4](https://github.com/antirez/ds4)**.
- A downloaded **GGUF model** (via ds4's `download_model.sh`). On a 128 GB Thor the
  `q2-q4-imatrix` (~91 GB) or `q2-imatrix` (~81 GB) quants run fully resident.

## Quick start

```sh
git clone https://github.com/vu2lid/ds4-thor-docker && cd ds4-thor-docker
cp .env.example .env && $EDITOR .env          # set DS4_SRC, MODEL_PATH, DS4_CUDA_ARCH, ...
./build.sh                                     # compiles ds4 for your arch + builds the image
docker compose up -d
docker logs -f ds4                             # wait for "listening on http://0.0.0.0:8000"
curl -s localhost:8000/v1/models | head -c 200
```

Cold model load takes ~100 s+ for a ~90 GB model; the healthcheck allows for it.

## Configuration (`.env`)

| Var | Meaning |
|-----|---------|
| `DS4_SRC` | Path to your `antirez/ds4` clone (built by `build.sh`) |
| `DS4_CUDA_ARCH` | `sm_110` (Thor), `sm_121` (Spark), or `native` |
| `CUDA_DIR` | Host CUDA dir bind‑mounted to `/usr/local/cuda` (e.g. `/usr/local/cuda-13.0`) |
| `MODEL_PATH` | Absolute path to your `.gguf` (**required**) |
| `DS4_CTX` | Server context window (keep in sync with your agent) |
| `DS4_PORT` | Published API port (default 8000) |
| `KV_BUDGET_MB`, `KV_COLD_MAX` | Disk KV budget + max cold‑prompt length to checkpoint |
| `KV_DIR`, `LOG_DIR` | Host dirs for checkpoints / optional traces |

## Persistent disk KV cache (why it matters)

ds4‑server can checkpoint KV state to disk (`--kv-disk-dir`, off by default upstream). This
image enables it to a host volume. On a long agent session, a large stable prefix (system prompt
+ tool context) gets **written** to `/kv-cache` and later **reloaded from disk** instead of being
re‑prefilled from scratch:

```
kv cache stored tokens=11103 reason=cold size=168.61 MiB save=338.7 ms
kv cache hit text tokens=11103 load=177.1 ms file=/kv-cache/<sha>.kv
```

Reloading an ~11k‑token prefix took **~0.2–0.5 s** vs. **~75 s** to cold‑prefill it — roughly
**150–400×** on that prefix — and it survives restarts/reboots because the checkpoints are on the
host. It also softens ds4's single‑stream KV eviction (evicted sequences spill to disk).

**Size the budget for your agent, and know what "full" means.** `--kv-disk-space-mb` is a *budget*,
not the filesystem — `kv cache evicted reason=disk-cache-full` means that budget filled, **not** that
the disk is full. Agent sessions churn through many checkpoints (each turn saves one; 21k‑token
prompts are ~300 MB each), so a small budget evicts the very prefixes you'd reuse next turn — which
shows up as repeated full re‑prefills. If your KV dir is on a roomy disk, raise it generously
(e.g. **`--kv-disk-space-mb 65536`** = 64 GiB) so prefix checkpoints survive across turns.

Caveat: even with room, an agent that *reconstructs* its prompt each turn (e.g. Aider) can still miss
the **live** cache (which needs an exact continuation → `reason=token-mismatch`); the disk cache is
what recovers the shared prefix, so keeping it large is what helps.

## Reboot behavior

The container uses `restart: unless-stopped`, so it comes back on reboot as long as the Docker
daemon is enabled on boot. (Caveat: a **manual** `docker stop` is remembered — after that, a reboot
will *not* auto‑start it; use `docker start ds4`.) Disk KV survives reboot, so the first prompts
reload from `/kv-cache` rather than cold‑prefilling.

## Memory footprint & coexistence

The model is held **resident** in unified memory to serve at full speed — ~90 GB for the q2‑q4
quant. On a 128 GB box that leaves little headroom for other GPU workloads (image generation, other
LLMs) *while ds4 is loaded*. Things we measured trying to shrink it:

- **SSD streaming** (`--ssd-streaming --ssd-streaming-cache-experts NGB`) streams experts from disk
  instead of full residency, but decode dropped to **~1 t/s (≈8× slower)** even from internal NVMe —
  this MoE activates too many experts per token. Not viable for interactive use.
- **Skipping host‑registration** does *not* turn the model into reclaimable page cache — ds4 loads
  weights into a CUDA device cache that still counts as *used*.
- So there is **no config that keeps ds4 fast while shrinking its RAM** — a fast ~90 GB model must be resident.

**`free` is misleading here.** After you stop ds4, the NVIDIA driver **lazy‑holds** its ~90 GB (it
shows as `used`, `available` stays low), but the kernel **reclaims it on demand** — a fresh process
can allocate that memory fine (verified: a 30 GiB allocation succeeds with ds4 "using" 117 G). So
stopping ds4 really does free the RAM for other apps, even though `free` doesn't reflect it.

**Practical answer: run ds4 on‑demand.** Stop it when you need the RAM (`docker stop ds4`), start it
(~25 s from NVMe) when you want the agent. To automate this — ds4 **down by default, woken by the
first request** and stopped after idle — see [`recipes/wake-on-request.md`](recipes/wake-on-request.md).

## Using `ds4-agent` (native coding agent)

The image also ships `ds4-agent` (built alongside `ds4-server` by `build.sh`, copied into
`/opt/ds4/ds4-agent`) — a terminal coding agent built directly into ds4: no HTTP/API layer, tool
calls and file edits happen in‑process, and session state lives in an on‑disk KV cache
(`~/.ds4/kvcache`, with `/save`, `/list`, `/switch`, `/del`, `/strip` commands). It's `alpha`
upstream — expect sharp edges.

**It loads its own copy of the model** rather than talking to an already‑running `ds4-server`, so it
can't run alongside a live server container without a GPU‑memory conflict. Stop the server first:

```sh
docker compose stop ds4
```

Run it as a one‑off container (same mounts as the compose service, entrypoint overridden):

```sh
docker run --rm --runtime nvidia \
  -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e DS4_CUDA_HOST_REGISTER_PLAIN=1 \
  -v "$CUDA_DIR":/usr/local/cuda:ro \
  -v "$MODEL_PATH":/models/model.gguf:ro \
  -v /path/to/your/project:/project \
  --entrypoint /opt/ds4/ds4-agent \
  ds4-thor:local \
  --cuda -m /models/model.gguf -c "$DS4_CTX" --chdir /project --non-interactive \
  -p "your instruction here"
```

`--non-interactive -p "..."` runs one turn and exits (scriptable, e.g. from CI or a wrapper script);
drop `-p` for an interactive REPL instead. `--chdir` resolves relative file paths from your project
root — get this wrong and it edits (or fails to find) the wrong files.

Restart the server when you're done:

```sh
docker compose start ds4
```

The reliability caveats in *Gotchas & operational notes* below apply just as much here — having its
own tool‑calling (it can search the codebase for callers, etc.) makes it a more capable
*investigator*, not a more *correct* one.

## Gotchas & operational notes

- **Build for the right arch.** Thor is `sm_110`, **not** the Spark's `sm_121`. Verify native SASS:
  `cuobjdump ds4-server | grep arch` → `arch = sm_110`. (`build.sh` checks this.)
- **A running container does not pick up `.env` changes.** `restart: unless-stopped` keeps serving
  with whatever values were in effect when the container was *created* — editing `MODEL_PATH` (or
  anything else) in `.env` has no effect until you `docker compose up -d --force-recreate`. Worse: if
  you bind‑mount a host path that doesn't currently exist (e.g. testing against a `MODEL_PATH` that's
  since moved), Docker silently **creates an empty directory** there instead of erroring — it can look
  like your multi‑GB model file vanished when it's actually just a stale path. Check what a *running*
  container is actually using with
  `docker inspect ds4 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'`,
  not just what `.env` currently says.
- **`DS4_CUDA_HOST_REGISTER_PLAIN=1` (set by default in the compose) prevents a GPU-wedging hang.**
  ds4 registers the model mmap with `Mapped|ReadOnly`. If that *fails* you see `CUDA host
  registration skipped: operation not supported` and it uses a fast mmap path — benign. If it
  *succeeds* (happens once there's enough free RAM to pin the whole model), the per‑tensor span
  prep **hangs at ~80–90% with one core pegged and wedges the whole GPU/GSP** (`NVRM
  rpcSendMessage failed … fn 76`; `nvidia-smi` and every GPU container die → reboot required).
  `DS4_CUDA_HOST_REGISTER_PLAIN=1` drops the ReadOnly flag and lets it complete. (A `memlock`
  ulimit does **not** constrain the pin — the driver manages it — so that's not a workaround.)
- **Put the model on fast, reliable local storage.** The model is memory‑mapped and demand‑paged;
  serving it from a slow/flaky disk (e.g. a USB‑SATA/NVMe bridge) can stall the mmap faults and
  hang the box. Internal NVMe strongly preferred.
- **Agent context window must match `DS4_CTX`.** ds4 hard‑rejects prompts ≥ context size with a
  `400 context_length_exceeded`. If your agent thinks the window is larger than the server's, it
  will overflow and its context‑condensing (which sends the whole history in one call) will fail
  too. Set the agent's window to `DS4_CTX` and its auto‑condense threshold to ~70–75%. Also cap
  per‑tool‑output size — a single huge file read can blow past the limit in one step.
- **Single‑stream server.** ds4 processes one request at a time and keeps a single live KV cache;
  running two concurrent sessions makes them evict each other's cache (full cold re‑prefills). Run
  one heavy session at a time.
- **Memory looks "stuck" after stopping ds4** — see *Memory footprint & coexistence* above. The
  driver lazy‑holds it but it's reclaimed on demand; `free` understates what's actually available.
- **Don't experiment with ds4's memory/registration config on a live box.** An OOM during load or a
  bad registration path can wedge the GPU/GSP (as above) and force a reboot. Change one variable at
  a time, reboot to a clean driver pool between trials if needed, and keep a known‑good compose as
  rollback. (We wedged the GPU twice learning this.)
- **Profiling with Nsight Compute** (`ncu`) on Jetson: GPU counters are admin‑only
  (`RmProfilingAdminOnly: 1`) so run under `sudo`; set `DS4_LOCK_FILE=/tmp/…` (env) to dodge ds4's
  single‑instance lock; and use `--replay-mode application` (default kernel‑replay fails backing up
  the multi‑GB model between passes). Decode runs through CUDA graphs, so some graph‑node kernels
  won't isolate.
- **MTP (speculative decoding) wasn't worth it** on the q2/q2‑q4 quants here: no speedup at
  `--mtp-draft 2`, and deeper drafts (`4/6`) were ~40% *slower* — draft tokens get rejected. Run plain greedy.
- **Cap the agent's response length.** Unbounded output on a ~8 t/s model is expensive: a 13k‑token
  review ≈ **27 min of decode**, which also bloats the next prompt and (with wake‑on‑request) can trip
  the idle‑stop. Lower `max_output_tokens` (e.g. 6000) and prompt for concise, severity‑ranked answers.
- **ds4 (and its native `ds4-agent`, see below) is a lead‑generator, not an autonomous editor.**
  Across repeated trials on a real codebase: only **~⅓–⅖** of proposed fixes were correct even with
  narrowly‑scoped SEARCH/REPLACE review; the *same* file/prompt/model produced different, sometimes
  mutually‑exclusive proposed bugs across independent runs (one file hit its timeout in **7 of 7**
  attempts, never converging); and a build/test gate reliably catches only what the test suite
  already covers — several confirmed‑bad edits passed cleanly because the exact edge case they broke
  wasn't tested. This isn't specific to one agent wrapper — `ds4-agent`'s own tool‑calling showed the
  same failure modes as a generic API‑driven agent, and in one directly‑compared case its fix was
  measurably *worse* than a simpler tool's fix for the identical bug. **Always gate behind build/tests
  and require a human to read every surviving diff** — don't trust a single "no bugs found" or a
  single "found a bug" verdict.

## Rollback / uninstall

```sh
docker compose down            # stop + remove the container (kv-cache/ + logs/ persist on host)
```

## Credits

- **ds4 / DwarfStar / DeepSeek‑V4‑Flash** — the actual engine and model: https://github.com/antirez/ds4
- Thor vs. Spark performance context: antirez/ds4 issue #183.
- This repo: container packaging + notes only. MIT (see `LICENSE`).
