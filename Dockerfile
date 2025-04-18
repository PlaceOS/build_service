ARG CRYSTAL_VERSION=latest

FROM placeos/crystal:$CRYSTAL_VERSION AS build
WORKDIR /app

# Set the commit via a build arg
ARG PLACE_COMMIT="DEV"
# Set the platform version via a build arg
ARG PLACE_VERSION="DEV"

# Disable HTTP::Client instrumentation
ENV OTEL_CRYSTAL_DISABLE_INSTRUMENTATION_HTTP_CLIENT=false

# Install sqlite3
RUN apk update && apk upgrade && apk add --no-cache sqlite-dev

# Install shards for caching
COPY shard.* .
RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Add src
COPY ./src /app/src

# Build application
RUN shards build --production --release --error-trace

FROM placeos/crystal:$CRYSTAL_VERSION

ENV HOME="/app"
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

# Install sqlite3
RUN apk update && apk upgrade && apk add --no-cache sqlite

# Create a non-privileged user, defaults are appuser:10001
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "${HOME}" \
    --shell "/sbin/nologin" \
    --uid "${UID}" \
    "${USER}"

WORKDIR /app

COPY --from=build /app/bin/build-api /app/
RUN chown appuser -R /app

# Use an unprivileged user
USER appuser:appuser

# Health check for the app
HEALTHCHECK CMD ["/app/build-api", "-c", "http://127.0.0.1:3000/api/build/v1"]

# Expose the app port
EXPOSE 3000
ENTRYPOINT ["/app/build-api"]
CMD ["/app/build-api", "-b", "0.0.0.0", "-p", "3000"]
