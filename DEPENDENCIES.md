# Dependencies

Native dependencies fetched by `libs/bootstrap.sh` and used by the build.

| Dependency | Version | License | Use |
|---|---|---|---|
| Zig | 0.16.0 | MIT | compiler + std |
| GLFW | 3.4 (tag `3.4`) | zlib/libpng license | window + input (platform layer) |
| Dawn (google/dawn) | `e5e4a685c9cc53473a458995c4ba5c8f68cec21a` (pinned in `libs/dawn.commit`) | BSD-3-Clause | WebGPU implementation (graphics backend) |
| CMake / Ninja / Jinja2 | latest | BSD-3-Clause / Apache-2.0 | Dawn build tooling (dev-only, in `.tools/`) |
| miniaudio | `9634bedb5b5a2ca38c1ee7108a9358a4e233f14d` (pinned in `libs/miniaudio.commit`) | MIT / Unlicense (public domain) | audio device + decode (M8) |

Pinned versions are authoritative in `libs/dawn.commit` (Dawn), `libs/miniaudio.commit` (miniaudio) and in the bootstrap script (GLFW tag).

## Planned for later milestones (not fetched yet)

| Dependency | Milestone | License |
|---|---|---|
| Box2D v3 | M4 | BSD-2-Clause |
| LuaJIT | M3 | MIT |
| Dear ImGui | M5 | MIT |
| ImGuizmo | M5 | MIT |

The engine is proprietary; see [LICENSE](LICENSE). Third-party licenses apply
only to the dependencies listed above.
