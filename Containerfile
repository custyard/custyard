# Build stage
# Keep in sync with .github/workflows/ci.yml
FROM elixir:1.18.3-otp-27-slim AS builder

RUN apt-get update && apt-get install -y git build-essential && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Set build env
ENV MIX_ENV=prod

# Copy config and deps first for caching
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

# Copy assets and compile
COPY assets assets
COPY priv priv
RUN mix assets.deploy

# Copy lib and compile
COPY lib lib
RUN mix compile

# Build release
RUN mix release

# Runtime stage
FROM debian:13-slim

LABEL org.opencontainers.image.source="https://github.com/onetimesecret/custyard"
LABEL org.opencontainers.image.description="Custyard Service Platform"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales curl && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Run as non-root user
RUN groupadd --system custyard && \
    useradd --system --gid custyard --home /app custyard

WORKDIR /app

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/custyard ./

# Create data directory for SQLite and set ownership
RUN mkdir -p /data && chown -R custyard:custyard /app /data

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER custyard

# Expose port
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:${PORT:-4000}/api/health

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bin/custyard", "start"]
