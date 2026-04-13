#!/bin/bash
# build-gitsafe-musl.sh — Build gitsafe as a fully static binary using musl libc
#
# Prerequisites:
#   - musl-gcc installed (apt install musl-tools)
#   - Chez Scheme built with: ./configure --threads --static CC=musl-gcc
#     and installed to ~/chez-musl (or set JERBOA_MUSL_CHEZ_PREFIX)
#   - Jerboa libraries available
#
# The build uses stock scheme (glibc) for the Scheme compilation steps,
# then musl-gcc for the C compilation and linking steps.
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
echo "Building gitsafe-musl (static)"
echo "==================================="
echo ""
echo "Jerboa: $JERBOA_LIB"
echo ""

# Check musl availability
if ! command -v musl-gcc &>/dev/null; then
    echo "ERROR: musl-gcc not found"
    echo "Install: sudo apt install musl-tools"
    exit 1
fi

echo "[1/2] Validating musl toolchain..."
echo "  musl-gcc: $(command -v musl-gcc)"
echo ""

echo "[2/2] Running musl build..."
scheme -q --libdirs "${SCRIPT_DIR}:${JERBOA_LIB}" --script build-gitsafe-musl.ss

# Verify
if [ -f "gitsafe-musl" ]; then
    echo ""
    echo "==================================="
    echo "gitsafe-musl built successfully!"
    echo "==================================="
    ls -lh gitsafe-musl
    echo ""
    file gitsafe-musl
    echo ""
    ldd gitsafe-musl 2>&1 || echo "  (Fully static — no dynamic dependencies)"
    echo ""
    echo "Test: ./gitsafe-musl --version"
    ./gitsafe-musl --version || { echo "ERROR: binary smoke test failed"; exit 1; }
else
    echo "ERROR: gitsafe-musl not created"
    exit 1
fi
