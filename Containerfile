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

# Copy application source
COPY lib lib

# Copy assets and static files for asset build (NOT migrations yet - they change frequently)
COPY assets assets
COPY priv/static priv/static
COPY priv/gettext priv/gettext
RUN mix assets.deploy

# Compile application
RUN mix compile

# Copy migrations and seeds (after compile - changes here won't invalidate compile cache)
COPY priv/repo priv/repo

# Package source code so Sentry stacktraces include source context
# (enable_source_code_context). Must run before the release is assembled.
RUN mix sentry.package_source_code

# Release overlays (bin/operator, bin/acknowledgments) and env.sh.eex, which
# turns Erlang distribution off. Copied late so edits here rebuild only the
# release, and checked so a missing or non-executable overlay fails the build.
COPY rel rel

# Build release
RUN mix release
RUN test -x _build/prod/rel/custyard/bin/operator && \
    test -x _build/prod/rel/custyard/bin/acknowledgments

# Runtime stage
# Use Debian 12 (bookworm) to match the Elixir builder image base.
# Avoids library version mismatches (libc, openssl) between build and runtime.
# Debian 13 (trixie) is testing-branch and packages change unpredictably.
FROM debian:12-slim

LABEL org.opencontainers.image.source="https://github.com/custyard/custyard"
LABEL org.opencontainers.image.description="Custyard Service Platform"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales curl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Run as non-root user
RUN groupadd --system custyard && \
    useradd --system --gid custyard --home /app custyard

WORKDIR /app

# Copy release from builder. It stays root-owned: under `fly ssh console`
# root runs /app/bin/operator and /app/bin/acknowledgments before they drop
# to custyard, so an app user able to write /app could plant code root runs.
COPY --from=builder /app/_build/prod/rel/custyard ./

# custyard writes only /data (SQLite, uploads) and /app/tmp (RELEASE_TMP,
# which `bin/custyard daemon` uses for its pipe and log, and crash dumps).
RUN mkdir -p /data /app/tmp && chown custyard:custyard /data /app/tmp

# The VM writes erl_crash.dump to its working directory (/app) by default.
ENV ERL_CRASH_DUMP=/app/tmp/erl_crash.dump

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
