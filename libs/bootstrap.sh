#!/usr/bin/env bash
# libs/bootstrap.sh — Fetches and builds the engine's native dependencies (M0).
#
# Usage:  bash libs/bootstrap.sh
#
# - cmake/ninja: local binaries in .tools/ (never touches the system)
# - jinja2: local venv in .tools/venv (required by Dawn's build)
# - GLFW: shallow clone of release 3.4
# - Dawn: shallow clone of the commit pinned in libs/dawn.commit + shared
#         Release build + install into libs/dawn/install
#
# Idempotent: re-running does not re-download what is already present.
# libs/dawn.commit is the single source of truth for the Dawn version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
LIBS="$ROOT/libs"
mkdir -p "$TOOLS" "$LIBS"

echo "==> Local tools in $TOOLS"
export PATH="$TOOLS/cmake/bin:$TOOLS:$TOOLS/venv/bin:$PATH"

# --- cmake (official binary) ------------------------------------------------
if [ ! -x "$TOOLS/cmake/bin/cmake" ]; then
  echo "==> Downloading cmake"
  tag="$(curl -fsSL https://api.github.com/repos/Kitware/CMake/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
  curl -fsSL -o "$TOOLS/cmake.tar.gz" \
    "https://github.com/Kitware/CMake/releases/download/v${tag}/cmake-${tag}-linux-x86_64.tar.gz"
  tar -xzf "$TOOLS/cmake.tar.gz" -C "$TOOLS"
  mv "$TOOLS/cmake-${tag}-linux-x86_64" "$TOOLS/cmake"
  rm -f "$TOOLS/cmake.tar.gz"
fi

# --- ninja (official binary) ------------------------------------------------
if [ ! -x "$TOOLS/ninja" ]; then
  echo "==> Downloading ninja"
  curl -fsSL -o "$TOOLS/ninja.zip" \
    https://github.com/ninja-build/ninja/releases/latest/download/ninja-linux.zip
  python3 -m zipfile -e "$TOOLS/ninja.zip" "$TOOLS"
  # python zipfile does not preserve the executable bit
  chmod +x "$TOOLS/ninja"
  rm -f "$TOOLS/ninja.zip"
fi

# --- venv with jinja2 (Dawn's generator needs it) ---------------------------
if [ ! -x "$TOOLS/venv/bin/python" ]; then
  echo "==> Creating venv with jinja2"
  python3 -m venv "$TOOLS/venv"
  "$TOOLS/venv/bin/pip" -q install jinja2
fi

# --- GLFW 3.4 ----------------------------------------------------------------
if [ ! -d "$LIBS/glfw/.git" ]; then
  echo "==> Cloning GLFW 3.4"
  git clone --depth 1 --branch 3.4 https://github.com/glfw/glfw "$LIBS/glfw"
fi
echo "glfw commit: $(git -C "$LIBS/glfw" rev-parse HEAD)"

# --- Dawn (pinned commit) ----------------------------------------------------
PIN="$(tr -d '[:space:]' < "$LIBS/dawn.commit")"
if [ ! -d "$LIBS/dawn/.git" ]; then
  echo "==> Cloning Dawn @ $PIN"
  git init -q "$LIBS/dawn"
  git -C "$LIBS/dawn" remote add origin https://github.com/google/dawn
  git -C "$LIBS/dawn" fetch -q --depth 1 origin "$PIN"
  git -C "$LIBS/dawn" checkout -q --detach FETCH_HEAD
elif [ "$(git -C "$LIBS/dawn" rev-parse HEAD)" != "$PIN" ]; then
  echo "==> Checking out the pinned Dawn commit $PIN"
  git -C "$LIBS/dawn" fetch -q --depth 1 origin "$PIN"
  git -C "$LIBS/dawn" checkout -q --detach FETCH_HEAD
fi
echo "dawn commit: $(git -C "$LIBS/dawn" rev-parse HEAD)"

# --- Box2D v3 (M4 physics) ---------------------------------------------------
# Pinned by TAG in libs/box2d.commit, unlike Dawn (pinned by commit): Box2D
# publishes tags, and a release tag is a far more stable thing to pin than a
# SHA on a moving branch.
B2PIN="$(tr -d '[:space:]' < "$LIBS/box2d.commit")"
if [ ! -d "$LIBS/box2d/.git" ]; then
  echo "==> Cloning Box2D @ $B2PIN"
  git clone --depth 1 --branch "$B2PIN" https://github.com/erincatto/box2d "$LIBS/box2d"
elif [ "$(git -C "$LIBS/box2d" describe --tags --exact-match 2>/dev/null || true)" != "$B2PIN" ]; then
  echo "==> Checking out Box2D $B2PIN"
  git -C "$LIBS/box2d" fetch -q --depth 1 origin "refs/tags/$B2PIN:refs/tags/$B2PIN"
  git -C "$LIBS/box2d" checkout -q --detach "refs/tags/$B2PIN"
fi
echo "box2d tag: $(git -C "$LIBS/box2d" describe --tags 2>/dev/null || echo "$B2PIN")"

# Box2D compiles with `-Werror` on its own target (src/CMakeLists.txt), which
# lands AFTER CMAKE_C_FLAGS and so cannot be overridden from the command line.
# GCC's strict-aliasing and maybe-uninitialized analyses fire false positives on
# its `offsetof(b2Vec2, ...)` field reads, so the build fails on a modern GCC.
# Relaxing it here — idempotently, re-applied on every run, never committed —
# is cheaper than patching a vendored dependency at every call site. It does not
# modify any Box2D source file, only its build flags.
if [ -f "$LIBS/box2d/src/CMakeLists.txt" ] && grep -q -- "-Werror" "$LIBS/box2d/src/CMakeLists.txt"; then
  echo "==> Relaxing Box2D -Werror (GCC false positives on offsetof)"
  sed -i 's/-Werror//g' "$LIBS/box2d/src/CMakeLists.txt"
fi
# The target also sets the CMake 3.24+ property `COMPILE_WARNING_AS_ERROR ON`,
# which expands to per-diagnostic `-Werror=<name>` flags — that is the one
# actually failing here, so the property has to go too.
if [ -f "$LIBS/box2d/src/CMakeLists.txt" ] && grep -q "COMPILE_WARNING_AS_ERROR" "$LIBS/box2d/src/CMakeLists.txt"; then
  sed -i 's/COMPILE_WARNING_AS_ERROR ON/COMPILE_WARNING_AS_ERROR OFF/' "$LIBS/box2d/src/CMakeLists.txt"
fi

if [ ! -d "$LIBS/box2d/install/lib" ]; then
  echo "==> Building Box2D v3 (Release)"
  # Box2D ships `-Werror`, and its `b2Vec2` fields are read through
  # `offsetof` in a way GCC's strict-aliasing analysis flags (false positive:
  # the accesses are to the same object). Downgrading to warnings keeps the
  # build working on a modern GCC without patching the dependency — we do not
  # modify vendored sources.
  cmake -S "$LIBS/box2d" -B "$LIBS/box2d/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LIBS/box2d/install" \
    -DBOX2D_SAMPLES=OFF -DBOX2D_UNIT_TESTS=OFF -DBOX2D_BENCHMARKS=OFF
  cmake --build "$LIBS/box2d/build" --target install
fi
echo "box2d installed: $(ls "$LIBS/box2d/install/lib" 2>/dev/null | tr '\n' ' ')"

echo "==> Configuring Dawn (dependency fetch included)"
cmake -S "$LIBS/dawn" -B "$LIBS/dawn/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DDAWN_BUILD_MONOLITHIC_LIBRARY=OFF \
  -DDAWN_FETCH_DEPENDENCIES=ON \
  -DDAWN_BUILD_EXAMPLES=OFF \
  -DDAWN_BUILD_TESTS=OFF \
  -DDAWN_ENABLE_DESKTOP_GL=OFF \
  -DDAWN_ENABLE_OPENGLES=OFF \
  -DDAWN_ENABLE_VULKAN=ON \
  -DDAWN_ENABLE_NULL=ON \
  -DDAWN_USE_X11=ON \
  -DCMAKE_INSTALL_PREFIX="$LIBS/dawn/install"

echo "==> Building Dawn (this takes several minutes)"
cmake --build "$LIBS/dawn/build" -j"$(nproc)"

echo "==> Installing Dawn into $LIBS/dawn/install"
cmake --install "$LIBS/dawn/build"

echo "==> Bootstrap complete"
