# libs/ — Native dependencies

Nothing in this folder is committed (see `.gitignore`): everything is obtained with:

```bash
bash libs/bootstrap.sh
```

## What it downloads

| Dependency | Version | Destination | Use |
|---|---|---|---|
| cmake | latest (official binary) | `.tools/cmake/` | Dawn build |
| ninja | latest (official binary) | `.tools/ninja` | Dawn build |
| jinja2 | latest (venv) | `.tools/venv/` | Dawn's generator |
| GLFW | 3.4 (tag) | `libs/glfw/` | window + input (platform layer) |
| Dawn | commit pinned in `libs/dawn.commit` | `libs/dawn/` + `install/` | graphics backend (WebGPU) |

## Rules

- The bootstrap is **idempotent**: it can be re-run without re-downloading.
- `libs/dawn.commit` is the single source of truth for the Dawn version; the
  same pin is recorded in `DEPENDENCIES.md`.
- The engine touches Dawn **only** through `src/engine/render/` (our own
  wrapper). `webgpu.h` is never included outside that module.
