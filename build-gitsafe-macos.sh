#!/bin/bash
# build-gitsafe-macos.sh — Build gitsafe as a maximally-static macOS binary
#
# Statically links: Chez kernel, lz4, zlib, ncurses
# Dynamically links: libSystem (libc/libpthread — always present on macOS), libiconv
#
# Prerequisites:
#   - Chez Scheme installed (brew install chezscheme)
#   - Jerboa libraries available
#   - Homebrew ncurses (brew install ncurses)
#
# Produces: ./gitsafe-macos (single binary, no Chez runtime needed at run time)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve jerboa
if [ -n "${JERBOA_HOME:-}" ]; then
    JERBOA_LIB="${JERBOA_HOME}/lib"
elif [ -d "${SCRIPT_DIR}/../jerboa/lib" ]; then
    JERBOA_LIB="$(realpath "${SCRIPT_DIR}/../jerboa/lib")"
elif [ -d "${HOME}/mine/jerboa/lib" ]; then
    JERBOA_LIB="${HOME}/mine/jerboa/lib"
else
    echo "ERROR: Cannot find Jerboa. Set JERBOA_HOME."
    exit 1
fi
export JERBOA_HOME="${JERBOA_HOME:-$(dirname "$JERBOA_LIB")}"

echo "==================================="
echo "Building gitsafe-macos (static libs)"
echo "==================================="
echo ""
echo "Jerboa: $JERBOA_LIB"

# Verify macOS
if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: This build script is for macOS only."
    exit 1
fi

# Check Chez
if ! command -v scheme &>/dev/null; then
    echo "ERROR: scheme not found"
    echo "Install: brew install chezscheme"
    exit 1
fi

echo "  scheme: $(command -v scheme) ($(scheme --version 2>&1))"
echo ""

echo "[1/2] Validating macOS build environment..."

# Check for ncurses static lib
NCURSES_A=""
for p in /opt/homebrew/opt/ncurses/lib /usr/local/opt/ncurses/lib; do
    if [ -f "$p/libncurses.a" ]; then
        NCURSES_A="$p/libncurses.a"
        break
    fi
done
if [ -z "$NCURSES_A" ]; then
    echo "WARNING: static libncurses.a not found, will use dynamic -lncurses"
    echo "  Install: brew install ncurses"
fi
export NCURSES_STATIC_PATH="${NCURSES_A}"
echo "  ncurses: ${NCURSES_A:-dynamic}"
echo ""

echo "[2/2] Running macOS build..."
scheme -q --libdirs "${SCRIPT_DIR}:${JERBOA_LIB}" --script build-gitsafe-macos.ss

# Verify
if [ -f "gitsafe-macos" ]; then
    echo ""
    echo "==================================="
    echo "gitsafe-macos built successfully!"
    echo "==================================="
    ls -lh gitsafe-macos
    echo ""
    file gitsafe-macos
    echo ""
    echo "Dynamic dependencies:"
    otool -L gitsafe-macos 2>/dev/null | tail -n +2 || true
    echo ""
    echo "Test: ./gitsafe-macos --version"
    ./gitsafe-macos --version || { echo "ERROR: binary smoke test failed"; exit 1; }
else
    echo "ERROR: gitsafe-macos not created"
    exit 1
fi
