# Build stage
FROM elixir:1.16-slim AS builder

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

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

RUN apt-get update && apt-get install -y libstdc++6 openssl libncurses6 locales && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/custyard ./

# Create data directory for SQLite
RUN mkdir -p /data

# Expose port
EXPOSE 4000

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bin/custyard", "start"]
