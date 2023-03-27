ARG CRYSTAL_VERSION=latest

FROM placeos/crystal:$CRYSTAL_VERSION as build
WORKDIR /app

# Set the commit via a build arg
ARG PLACE_COMMIT="DEV"
# Set the platform version via a build arg
ARG PLACE_VERSION="DEV"

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

# Use an unprivileged user.
USER appuser:appuser

# Spider-gazelle has a built in helper for health checks (change this as desired for your applications)
HEALTHCHECK CMD ["/app/build-api", "-c", "http://127.0.0.1:3000/api/build/v1"]

# Run the app binding on port 3000
EXPOSE 3000
ENTRYPOINT ["/app/build-api"]
CMD ["/app/build-api", "-b", "0.0.0.0", "-p", "3000"]

