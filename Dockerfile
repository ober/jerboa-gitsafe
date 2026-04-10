# Dockerfile — Build gitsafe-musl in a clean environment
#
# Produces a fully static binary with zero runtime dependencies.
# No Chez Scheme or Jerboa installation needed on the target host.
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

FROM ubuntu:24.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

# ── System dependencies ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    musl-tools \
    musl-dev \
    git \
    ca-certificates \
    libncurses-dev \
    uuid-dev \
    liblz4-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Set HOME early — everything under /build so no real paths leak into binary
ENV HOME=/build
WORKDIR /build

# ── Build Chez Scheme (stock glibc, for compilation steps) ───────────────────
RUN git clone --depth 1 https://github.com/ober/ChezScheme.git && \
    cd ChezScheme && \
    git submodule update --init --depth 1 && \
    ./configure --threads --disable-x11 --installprefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    cd /build && rm -rf ChezScheme

# ── Build Chez Scheme (musl, for static linking) ────────────────────────────
# Two-pass build:
#   Pass 1: Full build with stock gcc to generate boot files
#   Pass 2: Rebuild kernel only with musl-gcc --static, reusing boot files
RUN git clone https://github.com/ober/ChezScheme.git chez-musl-src && \
    cd chez-musl-src && \
    git submodule update --init && \
    ./configure --threads --disable-x11 --installprefix=/build/chez-musl && \
    make -j$(nproc) && \
    cp ta6le/boot/ta6le/petite.boot /tmp/petite.boot && \
    cp ta6le/boot/ta6le/scheme.boot /tmp/scheme.boot && \
    make clean && \
    ./configure --threads --disable-x11 --static CC=musl-gcc --installprefix=/build/chez-musl && \
    mkdir -p ta6le/boot/ta6le && \
    cp /tmp/petite.boot ta6le/boot/ta6le/ && \
    cp /tmp/scheme.boot ta6le/boot/ta6le/ && \
    make -j$(nproc) kernel && \
    make install && \
    cd /build && rm -rf chez-musl-src /tmp/petite.boot /tmp/scheme.boot

# ── Clone Jerboa ─────────────────────────────────────────────────────────────
ARG CACHE_BUST=0
WORKDIR /build/mine
RUN git clone --depth 1 https://github.com/ober/jerboa.git

# ── Copy gitsafe source ─────────────────────────────────────────────────────
COPY . /build/mine/jerboa-gitsafe

# ── Build gitsafe-musl ───────────────────────────────────────────────────────
ENV JERBOA_MUSL_CHEZ_PREFIX=/build/chez-musl
ENV JERBOA_HOME=/build/mine/jerboa
WORKDIR /build/mine/jerboa-gitsafe
RUN make gitsafe-musl-local

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
