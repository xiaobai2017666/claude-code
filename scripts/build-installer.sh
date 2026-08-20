#!/usr/bin/env bash
# Build a self-extracting installer (ccc-install.sh) from dist/.
# The installer embeds a tar.gz of the runtime files (dist/ + scripts/postinstall.cjs)
# and installs them so that `ccc` runs dist/cli.js with bun or node.
#
# Cross-platform strategy:
#   - macOS/Linux, x64/arm64: launcher picks bun (preferred) or node (>= 20).
#   - ripgrep: downloaded at install time by scripts/postinstall.cjs for the
#     target machine's platform (microsoft/ripgrep-prebuilt, mirrors + proxy
#     supported). Falls back to system rg on failure. Use --offline to skip.
#   - WSL1: bun does not work under the WSL1 syscall translation layer, so the
#     launcher prefers node there. /proc/version containing "microsoft" without
#     a "WSL<n>" marker identifies WSL1 (same heuristic as src/utils/platform.ts).
#   - sharp (image paste/preview): optional, install with --with-sharp.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
OUT="$ROOT/release/ccc-install.sh"
VERSION="$(bun -e "console.log(require('$ROOT/package.json').version)" 2>/dev/null || echo unknown)"

if [[ ! -f "$DIST/cli.js" ]]; then
  echo "error: $DIST/cli.js not found — run 'bun run build' first" >&2
  exit 1
fi

mkdir -p "$ROOT/release"

STAGING="$(mktemp -d /tmp/ccc-staging.XXXXXX)"
trap 'rm -rf "$STAGING" "$TARBALL"' EXIT
TARBALL="$(mktemp /tmp/ccc-dist.XXXXXX.tar.gz)"

echo "==> Staging dist/ + scripts/postinstall.cjs (excluding .map files)..."
mkdir -p "$STAGING/dist" "$STAGING/scripts"
cp -R "$DIST/." "$STAGING/dist/"
cp "$ROOT/scripts/postinstall.cjs" "$STAGING/scripts/postinstall.cjs"

# .map files are excluded from the tarball below — strip the dangling
# sourceMappingURL comments too, or bun prints "Could not decode sourcemap"
# warnings on every startup.
find "$STAGING/dist" -name '*.js' -exec sed -i '/^\/\/# sourceMappingURL=/d' {} +

# ws is left as a bare import by Bun.build (Bun implements it natively, so bun
# runs fine), but Node's ESM linker fails on it at startup. Ship the pure-JS
# package next to dist/ so both runtimes resolve it (zero runtime deps).
if [[ -d "$ROOT/node_modules/ws" ]]; then
  mkdir -p "$STAGING/node_modules"
  # -L dereferences: node_modules/ws is a symlink into .bun/ under bun's
  # isolated installs — copying the link itself would ship a dangling path.
  cp -RL "$ROOT/node_modules/ws" "$STAGING/node_modules/ws"
  find "$STAGING/node_modules/ws" -name '*.md' -delete
else
  echo "error: node_modules/ws not found — Node.js installs would be broken" >&2
  exit 1
fi

echo "==> Packing..."
tar -czf "$TARBALL" -C "$STAGING" --exclude='*.map' .

echo "==> Generating self-extracting installer: $OUT"

cat >"$OUT" <<'INSTALLER_EOF'
#!/bin/sh
# ccc self-extracting installer — installs the Claude Code (ccc) CLI.
# Usage:
#   ./ccc-install.sh [--prefix DIR] [--offline] [--with-sharp] [--uninstall]
# Defaults: prefix=$HOME/.local
#   payload    -> $prefix/share/ccc/dist
#   rg binary  -> $prefix/share/ccc/dist/vendor/ripgrep (downloaded at install)
#   launcher   -> $prefix/bin/ccc
set -eu

PREFIX="$HOME/.local"
OFFLINE=0
WITH_SHARP=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX="${2:?--prefix requires a directory}"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      shift
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    --with-sharp)
      WITH_SHARP=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h | --help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *)
      echo "ccc-install: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

LIB_DIR="$PREFIX/share/ccc"
BIN_DIR="$PREFIX/bin"
LAUNCHER="$BIN_DIR/ccc"

if [ "$UNINSTALL" -eq 1 ]; then
  rm -rf "$LIB_DIR"
  rm -f "$LAUNCHER"
  echo "ccc: uninstalled from $PREFIX"
  exit 0
fi

# --- Runtime selection ---
# is_wsl1: /proc/version mentions Microsoft without a WSL<n> release marker.
# bun cannot run under the WSL1 syscall translation layer; node works fine.
is_wsl1() {
  [ -r /proc/version ] || return 1
  grep -qi microsoft /proc/version 2>/dev/null || return 1
  ! grep -qi 'wsl[0-9]' /proc/version 2>/dev/null
}

node_major_version() {
  node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
}

check_node_version() {
  NODE_MAJOR="$(node_major_version)"
  NODE_MAJOR="${NODE_MAJOR#v}"
  if [ "$NODE_MAJOR" -lt 20 ]; then
    echo "ccc: error: node >= 20 is required (found $(node --version))." >&2
    echo "  Install Node.js >= 20 (https://nodejs.org) or bun (https://bun.sh)." >&2
    exit 1
  fi
}

RUNTIME=""
if command -v bun >/dev/null 2>&1 && bun --version >/dev/null 2>&1; then
  if is_wsl1 && command -v node >/dev/null 2>&1; then
    RUNTIME=node
  else
    RUNTIME=bun
  fi
fi
if [ -z "$RUNTIME" ]; then
  if command -v node >/dev/null 2>&1; then
    RUNTIME=node
  elif command -v bun >/dev/null 2>&1; then
    RUNTIME=bun
  fi
fi
if [ -z "$RUNTIME" ]; then
  echo "ccc-install: error: neither bun nor node found in PATH." >&2
  echo "  Install bun (https://bun.sh) or node (https://nodejs.org) first." >&2
  exit 1
fi
if [ "$RUNTIME" = "node" ]; then
  check_node_version
fi

ARCHIVE_LINE=$(awk '/^__CCC_ARCHIVE_BELOW__$/ { print NR + 1; exit 0; }' "$0")
if [ -z "$ARCHIVE_LINE" ]; then
  echo "ccc-install: error: corrupted installer (archive marker not found)" >&2
  exit 1
fi

echo "ccc-install: installing to $LIB_DIR (runtime: $RUNTIME)"
mkdir -p "$LIB_DIR" "$BIN_DIR"
rm -rf "${LIB_DIR:?}"/* 2>/dev/null || true
tail -n +"$ARCHIVE_LINE" "$0" | tar -xz -C "$LIB_DIR"

cat >"$LAUNCHER" <<EOF
#!/bin/sh
# ccc launcher — generated by ccc-install.sh
LIB_DIR="$LIB_DIR"

ccc_is_wsl1() {
  [ -r /proc/version ] || return 1
  grep -qi microsoft /proc/version 2>/dev/null || return 1
  ! grep -qi 'wsl[0-9]' /proc/version 2>/dev/null
}

ccc_check_node() {
  NODE_MAJOR="\$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  NODE_MAJOR="\${NODE_MAJOR#v}"
  if [ "\$NODE_MAJOR" -lt 20 ]; then
    echo "ccc: error: node >= 20 is required (found \$(node --version))." >&2
    echo "  Install Node.js >= 20 (https://nodejs.org) or bun (https://bun.sh)." >&2
    exit 1
  fi
}

# WSL1: bun is broken under the syscall translation layer — prefer node.
if ccc_is_wsl1 && command -v node >/dev/null 2>&1; then
  ccc_check_node
  exec node "\$LIB_DIR/dist/cli.js" "\$@"
fi

if command -v bun >/dev/null 2>&1 && bun --version >/dev/null 2>&1; then
  exec bun "\$LIB_DIR/dist/cli.js" "\$@"
fi

if command -v node >/dev/null 2>&1; then
  ccc_check_node
  exec node "\$LIB_DIR/dist/cli.js" "\$@"
fi

echo "ccc: error: bun or node is required" >&2
exit 1
EOF
chmod +x "$LAUNCHER"

# --- ripgrep: download for this machine's platform (non-fatal) ---
if [ "$OFFLINE" -eq 1 ]; then
  echo "ccc-install: --offline given, skipping ripgrep download (system rg will be used)"
elif [ ! -x "$LIB_DIR/dist/vendor/ripgrep/$("$RUNTIME" -p 'process.arch + "-" + process.platform' 2>/dev/null || echo unknown)/rg" ] \
  && [ ! -f "$LIB_DIR/dist/vendor/ripgrep/$("$RUNTIME" -p 'process.arch + "-" + process.platform' 2>/dev/null || echo unknown)/rg.exe" ]; then
  echo "ccc-install: downloading ripgrep for this platform..."
  if ! "$RUNTIME" "$LIB_DIR/scripts/postinstall.cjs"; then
    echo "ccc-install: warn: ripgrep download failed — ccc will fall back to system rg." >&2
    echo "  Set RIPGREP_DOWNLOAD_BASE to a mirror if GitHub is unreachable (see scripts/postinstall.cjs)." >&2
  fi
else
  echo "ccc-install: vendored ripgrep already present, skipping download"
fi

# --- sharp: optional native image support ---
if [ "$WITH_SHARP" -eq 1 ]; then
  if command -v npm >/dev/null 2>&1; then
    echo "ccc-install: installing sharp (image paste/preview support)..."
    if ! (cd "$LIB_DIR" && npm install --no-save --no-audit --no-fund sharp@0.34.5); then
      echo "ccc-install: warn: sharp install failed — image paste/preview stays degraded." >&2
    fi
  else
    echo "ccc-install: warn: --with-sharp needs npm in PATH, skipping." >&2
  fi
fi

echo "ccc-install: installed launcher -> $LAUNCHER"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "  NOTE: $BIN_DIR is not in your PATH. Add it, e.g.:"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo "  (append that line to ~/.bashrc or ~/.zshrc to make it permanent)"
    ;;
esac

echo "ccc-install: done. Run 'ccc --version' to verify."
exit 0

__CCC_ARCHIVE_BELOW__
INSTALLER_EOF

cat "$TARBALL" >>"$OUT"
chmod +x "$OUT"

SIZE="$(du -h "$OUT" | cut -f1)"
echo "==> Done: $OUT ($SIZE, version $VERSION)"
