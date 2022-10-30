FROM ghcr.io/evanrichter/cargo-fuzz as builder
RUN apt update && apt install fonts-cantarell libcairo2-dev libharfbuzz-dev librsvg2-dev

ADD . /pris
WORKDIR /pris/fuzz
RUN cargo +nightly fuzz build 

FROM debian:bookworm
COPY --from=builder /pris/fuzz/target/x86_64-unknown-linux-gnu/release/pris-fuzz /