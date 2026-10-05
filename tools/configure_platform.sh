#!/usr/bin/env bash
# Generate headers from the pinned upstream source, executing configure probes.
# Run Linux targets in the matching native/emulated container. macOS x86_64 on
# Apple Silicon requires Rosetta so configure can execute its target binaries.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
platform=${1:?usage: configure_platform.sh <macos-arm64|macos-x86_64|linux-aarch64|linux-x86_64>}
machine=$(uname -m)
os=$(uname -s)
configure_target=()
case "$platform:$os:$machine" in
    macos-arm64:Darwin:arm64) export CC=clang CFLAGS='-arch arm64' ;;
    macos-x86_64:Darwin:arm64|macos-x86_64:Darwin:x86_64)
        export CC=clang CFLAGS='-arch x86_64'
        configure_target=(--build=x86_64-apple-darwin --host=x86_64-apple-darwin) ;;
    linux-aarch64:Linux:aarch64|linux-x86_64:Linux:x86_64) export CC=clang ;;
    *) echo "cannot configure $platform on $os/$machine; use the matching platform" >&2; exit 1 ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-pg-config.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
if [[ $os == Linux ]]; then
    cat >"$tmp/libc.c" <<'C'
#include <features.h>
#ifndef __GLIBC__
#error "these config directories are for glibc; musl needs separate source selection and configuration"
#endif
int main(void) { return 0; }
C
    clang "$tmp/libc.c" -o "$tmp/libc"
    "$tmp/libc"
fi
archive="$tmp/postgresql-18.0.tar.bz2"
curl -fL https://ftp.postgresql.org/pub/source/v18.0/postgresql-18.0.tar.bz2 -o "$archive"
if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$archive" | cut -d ' ' -f 1)
else
    actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
fi
test "$actual" = 0d5b903b1e5fe361bca7aa9507519933773eb34266b1357c4e7780fdee6d6078 || {
    echo "upstream archive checksum differs" >&2; exit 1;
}
tar -xjf "$archive" -C "$tmp"
cd "$tmp/postgresql-18.0"
./configure "${configure_target[@]}" --without-openssl --without-gssapi --without-icu \
    --without-readline --without-zlib --without-libxml --without-lz4 --without-zstd \
    >"$tmp/configure.log" 2>&1 || { cat "$tmp/configure.log" >&2; exit 1; }
# A cross configure does not execute the target's tests and cannot establish
# this package's ABI facts; force the contributor to provide execution evidence.
grep -q 'checking whether we are cross compiling.*no$' "$tmp/configure.log" || {
    cat "$tmp/configure.log" >&2; echo "configure did not execute native probes" >&2; exit 1;
}
make -C src/port pg_config_paths.h
output="$ROOT/vendor/postgresql/config/$platform"
mkdir -p "$output"
cp -L src/include/pg_config.h src/include/pg_config_os.h src/port/pg_config_paths.h "$output/"
uname -a
clang --version
cat "$tmp/configure.log"
echo "generated $platform headers; run vendor compilation and database suites before claiming support"
