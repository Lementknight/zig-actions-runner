# syntax=docker/dockerfile:1
# The runner as a container image: one static binary and the CA certificates it verifies GitHub and
# the database with, nothing else (about 2 MB). Zig cross-compiles, so the build stage runs on the
# build machine's platform for every target platform.
#
#   docker build -t zig-runner runner/
#   docker buildx build --platform linux/amd64,linux/arm64 -t <registry>/zig-runner runner/
#
# Steps run in the Dagger engine, not here; see docs/DEPLOY.md for running the two together.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS build
ARG ZIG_VERSION=0.17.0
ARG TARGETARCH
# What `--version` and every job's "Set up job" report. The build context holds no `.git`, so the
# version cannot be derived here: unset, the binary falls back to the package version, which says
# nothing about which build it is. The release workflow passes the tag.
ARG VERSION=
RUN apk add --no-cache curl xz ca-certificates
RUN arch="$(uname -m)" \
 && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
 && ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN case "$TARGETARCH" in \
      amd64) target=x86_64-linux-musl ;; \
      arm64) target=aarch64-linux-musl ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && zig build -Doptimize=ReleaseSafe -Dstrip -Dtarget="$target" ${VERSION:+-Dversion="$VERSION"} --prefix /out

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/bin/runner /runner
# SIGTERM (docker stop) lets running jobs finish; give it time (see stop_grace_period in compose).
STOPSIGNAL SIGTERM
ENTRYPOINT ["/runner"]
