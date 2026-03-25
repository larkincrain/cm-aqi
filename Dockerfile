# Dockerfile for building a Phoenix release.
#
# This is a multi-stage Docker build:
# 1. Build stage: Compiles Elixir code and assets into a release
# 2. Runtime stage: Runs the compiled release in a minimal container
#
# Multi-stage builds keep the final image small by excluding build tools.

# ============================================================================
# Stage 1: Build
# ============================================================================
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.1
ARG DEBIAN_VERSION=bookworm-20260316-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the working directory inside the container
WORKDIR /app

# Install Hex (Elixir's package manager) and Rebar (Erlang build tool)
RUN mix local.hex --force && \
    mix local.rebar --force

# Set the build environment to production
ENV MIX_ENV="prod"

# Install dependencies first (these change less often, so Docker caches this layer)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy config files (needed for compilation)
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy application source code
COPY priv priv
COPY lib lib
COPY assets assets

# Compile the application FIRST — Phoenix 1.8 colocated hooks
# require the Elixir code to be compiled before assets can be bundled.
COPY config/runtime.exs config/
RUN mix compile

# Compile assets (CSS and JavaScript) — must come after mix compile
RUN mix assets.deploy

# Build the release
# A "release" is a self-contained package of your compiled app + Erlang runtime.
# It can run on any machine without needing Elixir or Erlang installed.
RUN mix release

# ============================================================================
# Stage 2: Runtime
# ============================================================================
FROM ${RUNNER_IMAGE}

# Install runtime dependencies only
RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"

# Copy the compiled release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/cm_aqi ./

# Run as non-root user for security
USER nobody

# The command to start the application
CMD ["/app/bin/server"]
