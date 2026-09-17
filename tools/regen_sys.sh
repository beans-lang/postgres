#!/usr/bin/env bash
# Regenerates sys/sys.b from the vendored libpq header. Committed output, so
# a consumer never runs bindgen; this exists so an upgrade is reproducible.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BEANSC=${BEANSC:-$(command -v beansc)}
# libpq-fe.h says #include "postgres_ext.h", which upstream reaches through
# an -I the Makefile supplies. bindgen takes no extra clang flags, so the two
# headers are staged side by side for the one call.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$ROOT/vendor/postgresql/src/interfaces/libpq/libpq-fe.h" \
   "$ROOT/vendor/postgresql/src/interfaces/libpq/libpq-events.h" \
   "$ROOT/vendor/postgresql/src/include/postgres_ext.h" "$stage/"

"$BEANSC" bindgen "$stage/libpq-fe.h" \
    -o "$ROOT/sys/sys.b" --package sys --pub --allow-unsupported
echo "wrote sys/sys.b"
