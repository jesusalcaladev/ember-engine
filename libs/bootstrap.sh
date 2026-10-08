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
