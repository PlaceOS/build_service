# Test Container
###############################################################################
ARG crystal_version=latest
FROM placeos/crystal:${crystal_version} AS test

WORKDIR /app

# - Add sqlite3
# - Add libunwind static/dev so driver binaries compiled in the test image
#   produce fully-symbolized stack traces on static musl builds.
# - Add xz-static / xz-dev because Alpine's libunwind is built with liblzma
#   support and its ELF module objects pull in `lzma_*` symbols at link time.
RUN apk update && apk upgrade
# hadolint ignore=DL3018
RUN apk add --no-cache \
    sqlite-dev \
    libunwind-static \
    libunwind-dev \
    xz-static \
    xz-dev && \
    ln -sf /usr/lib/libsqlite3.so.0 /usr/lib/libsqlite3.so

# - Add watchexec for running tests on change
# hadolint ignore=DL3018
RUN apk add \
    --update \
    --no-cache \
    --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    watchexec


COPY test-scripts /app/scripts

ENTRYPOINT ["/app/scripts/test-entrypoint.sh"]
