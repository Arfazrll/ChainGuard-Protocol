# syntax=docker/dockerfile:1
FROM rust:1.88-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY data ./data
COPY config ./config
RUN cargo build --release --locked -p chainguard-ingestd

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /var/lib/chainguard chainguard \
 && mkdir -p /var/lib/chainguard && chown chainguard /var/lib/chainguard
WORKDIR /app
COPY --from=build /src/target/release/chainguard-ingestd /usr/local/bin/chainguard-ingestd
COPY data ./data
COPY config ./config
USER chainguard
ENTRYPOINT ["chainguard-ingestd"]
