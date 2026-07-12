# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz). Builds ON TOP of the
# org C/C++ base (ghcr.io/mayhemheroes/base), adding a pinned Rust toolchain +
# cargo-fuzz under /opt/toolchains/rust, then runs the per-repo mayhem/build.sh.
#
# pris renders slides through C libraries (cairo, harfbuzz, rsvg, fontconfig,
# freetype) declared as #[link] in-crate, so the native -dev packages (plus a real
# font for the examples oracle) are installed as a root step below.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────
# Pin the channel by DATE: -Zsanitizer=address (the OSS-Fuzz Rust ASan path) needs
# nightly, and a dated nightly keeps the build reproducible. Pin cargo-fuzz too.
ARG RUST_CHANNEL=nightly-2025-01-15
ARG CARGO_FUZZ_VERSION=0.12.0

# RUSTUP_TOOLCHAIN overrides the repo-root rust-toolchain file (which pins 1.28.0 from
# 2018) — the image ships exactly ONE toolchain and the offline PATCH re-run must never
# try to download another.
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    RUSTUP_TOOLCHAIN=${RUST_CHANNEL} \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root

# Native libraries pris links against (#[link] in src/: cairo, harfbuzz, rsvg-2,
# gobject-2.0, fontconfig; crate dep freetype-rs) + a font so the examples render.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libcairo2-dev libharfbuzz-dev librsvg2-dev libfontconfig1-dev \
        libfreetype6-dev fonts-cantarell fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the cargo registry cache, so hand the whole
 # prefix to 2000. (Task-tier lockdown re-locks it per type; PATCH keeps it usable.)
 && chown -R 2000:2000 /opt/toolchains/rust

# The prebuilt std rlibs and the sanitizer runtime (librustc-nightly_rt.asan.a) shipped
# in this nightly carry DWARF-5 debug info that Mayhem's triage can't read (§6.2 item 10).
# rustc's -Zdwarf-version only governs code we compile, not these prebuilt archives, so
# strip debug info from them (triage needs no runtime symbols) — the linked fuzz binary
# then carries only our DWARF-3 debug info.
RUN set -eux; RUSTLIB="$(rustc --print target-libdir)"; \
    for a in "$RUSTLIB"/*.rlib "$RUSTLIB"/librustc-nightly_rt.*.a; do \
      [ -e "$a" ] || continue; \
      objcopy --strip-debug "$a" 2>/dev/null || strip --strip-debug "$a" 2>/dev/null || true; \
    done

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target(s).
RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
