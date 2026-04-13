# Dockerfile — Build gitsafe-musl using the jerboa21/jerboa base image
#
# Produces a fully static binary with zero runtime dependencies.
# No Chez Scheme or Jerboa installation needed on the target host.
#
# The base image (jerboa21/jerboa) provides stock Chez, musl Chez,
# jerboa libs, and all build dependencies pre-installed.
#
# Usage:
#   docker build -t gitsafe-builder .
#   docker run --rm gitsafe-builder > gitsafe-musl && chmod +x gitsafe-musl
#
# Or extract via docker cp:
#   docker build -t gitsafe-builder .
#   id=$(docker create gitsafe-builder)
#   docker cp $id:/out/gitsafe-musl ./gitsafe-musl
#   docker cp $id:/out/gitsafe-musl.sha256 ./gitsafe-musl.sha256
#   docker rm $id

FROM jerboa21/jerboa AS builder

# ── Override stale baked-in Jerboa with host version ────────────────────────
# The base image ships an older Jerboa; overlay it so the build sees the same
# prelude exports (meta, atom?, etc.) as the local macOS build.
COPY --from=jerboa . /build/mine/jerboa/

# ── Copy gitsafe source ─────────────────────────────────────────────────────
COPY . /build/mine/jerboa-gitsafe

# ── Build gitsafe-musl ───────────────────────────────────────────────────────
WORKDIR /build/mine/jerboa-gitsafe
RUN make linux-local

# ── Verify ───────────────────────────────────────────────────────────────────
RUN ./gitsafe-musl --version
RUN echo "--- Binary info ---" && \
    ls -lh gitsafe-musl && \
    file gitsafe-musl && \
    echo "--- Hardening checks ---" && \
    { file gitsafe-musl | grep -qE 'stripped|no section header' && echo "  PASS: stripped" || echo "  FAIL: not stripped"; } && \
    { test -f gitsafe-musl.sha256 && echo "  PASS: integrity hash present" || echo "  FAIL: no hash"; } && \
    echo "--- Path leak check ---" && \
    count=$(strings gitsafe-musl | grep -c '/home/' || true) && \
    { [ "$count" -gt 0 ] && echo "  WARNING: home paths found ($count)" || echo "  PASS: no home path leaks"; }

# ── Output ───────────────────────────────────────────────────────────────────
FROM ubuntu:24.04
COPY --from=builder /build/mine/jerboa-gitsafe/gitsafe-musl /out/gitsafe-musl
COPY --from=builder /build/mine/jerboa-gitsafe/gitsafe-musl.sha256 /out/gitsafe-musl.sha256
CMD ["cat", "/out/gitsafe-musl"]
