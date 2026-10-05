#!/usr/bin/env bash
# These are C preprocessing checks, independent of Beans type checking.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-pg-selectors.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
headers=(src/include/pg_config.h src/include/pg_config_os.h src/port/pg_config_paths.h)
for target in arm64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu; do
    for header in "${headers[@]}"; do
        clang --target="$target" -E -x c "$ROOT/vendor/postgresql/$header" > /dev/null
    done
done
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
    for header in "${headers[@]}"; do
        if clang --target="$target" -DBEANS_POSTGRES_UNCONFIGURED_LIBC -E -x c "$ROOT/vendor/postgresql/$header" > /dev/null 2>"$tmp/error"; then
            echo "$header selected a glibc configuration for $target" >&2; exit 1
        fi
        grep -q 'no validated musl configuration' "$tmp/error"
    done
done
for target in riscv64-unknown-linux-gnu i686-unknown-linux-gnu aarch64-pc-windows-msvc x86_64-pc-windows-gnu arm64-apple-ios x86_64-apple-ios-simulator; do
    for header in "${headers[@]}"; do
        if clang --target="$target" -E -x c "$ROOT/vendor/postgresql/$header" > /dev/null 2>"$tmp/error"; then
            echo "$header silently selected a configuration for $target" >&2; exit 1
        fi
        grep -Eq 'no validated postgres configuration|Windows configuration and port sources are not validated' "$tmp/error"
    done
done
echo "ok platform selectors: 4 configured triples preprocess, 6 unsupported triples and 2 musl targets refuse"
