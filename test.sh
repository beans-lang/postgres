#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../beans" && pwd)
elif [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
if [[ -z ${BEANSC:-} ]]; then
    if [[ -n ${BEANS_ROOT:-} && -x "$BEANS_ROOT/build/beansc" ]]; then
        BEANSC="$BEANS_ROOT/build/beansc"
    else
        BEANSC=$(command -v beansc || true)
    fi
fi
if [[ -z "$BEANSC" ]] || [[ ! -x "$BEANSC" && ! -f "$BEANSC" ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi

PG_PORT=${BEANS_PG_PORT:-55432}
export BEANS_PG_PORT="$PG_PORT"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ -n ${BEANS_ROOT:-} && "$BEANSC" == "$BEANS_ROOT/build/beansc" ]]; then
    cd "$BEANS_ROOT"
fi

# GNU timeout is not on macOS. A suite with no wall clock can never go red.
run() { perl -e 'alarm shift; exec @ARGV' 300 "$@"; }

# ---- vendor integrity, before anything else ----------------------------------
#
# A relay header that lost its marker, or a config directory that moved, would
# otherwise be found at build time on one platform and never on the others.
for h in pg_config.h pg_config_os.h; do
    grep -q "beans relay header — NOT upstream" \
        "$ROOT/vendor/postgresql/src/include/$h" \
        || { echo "vendor/postgresql/src/include/$h lost its relay marker" >&2; exit 1; }
done
grep -q "beans relay header — NOT upstream" \
    "$ROOT/vendor/postgresql/src/port/pg_config_paths.h" \
    || { echo "vendor/postgresql/src/port/pg_config_paths.h lost its relay marker" >&2; exit 1; }

# Every committed configuration selected by the relays needs three headers.
# A hard failure, never a skip: a gate that skips on a missing input dies
# silently the moment the layout moves.
platforms=(macos-arm64 macos-x86_64 linux-aarch64 linux-x86_64)
for platform in "${platforms[@]}"; do
    for h in pg_config.h pg_config_os.h pg_config_paths.h; do
        [[ -f "$ROOT/vendor/postgresql/config/$platform/$h" ]] \
            || { echo "vendor/postgresql/config/$platform/$h is missing" >&2; exit 1; }
    done
done

# Every csrc row names a file that exists.
missing=0
while read -r file; do
    [[ -f "$ROOT/$file" ]] || { echo "beans.pot names a missing csrc file: $file" >&2; missing=1; }
done < <(grep '^csrc ' "$ROOT/beans.pot" | sed 's/.*"\(.*\)"/\1/')
[[ $missing -eq 0 ]] || exit 1
rows=$(grep -c '^csrc ' "$ROOT/beans.pot")
echo "ok vendor integrity: $rows csrc rows, relay markers intact, ${#platforms[@]} platform configs"
bash "$ROOT/tests/platform_config.sh"

# ---- suites ------------------------------------------------------------------
suites=(smoke crud notify pool)

have_server=0
if (exec 3<>"/dev/tcp/127.0.0.1/$PG_PORT") 2>/dev/null; then have_server=1; fi

if [[ $have_server -eq 0 ]]; then
    if [[ ${BEANS_DB_ALLOW_SKIP:-0} == 1 ]]; then
        echo "SKIPPED ${#suites[@]} of ${#suites[@]} suites — this run proved nothing about the server path"
    else
        echo "no postgres on 127.0.0.1:$PG_PORT." >&2
        echo "  start one:  docker run -d --name beans_db_pg -p $PG_PORT:5432 \\" >&2
        echo "                -e POSTGRES_USER=beans -e POSTGRES_PASSWORD=beans \\" >&2
        echo "                -e POSTGRES_DB=beansdb postgres:18" >&2
        echo "  or set BEANS_DB_ALLOW_SKIP=1 to skip the server suites on purpose." >&2
        exit 1
    fi
else
    for name in "${suites[@]}"; do
        run "$BEANSC" run "$ROOT/tests/$name.b" >"$tmp/$name.interp" 2>/dev/null
        diff -u "$ROOT/tests/$name.out" "$tmp/$name.interp"
    done
    echo "ok server: ${#suites[@]} suites against postgres on :$PG_PORT"
fi

for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-musl; do
    run "$BEANSC" check "$ROOT/tests/smoke.b" --target "$target" >/dev/null
done
echo "ok cross-target checks: 2 targets"

run "$BEANSC" check "$ROOT/di/tests/container.b" >/dev/null
echo "ok sibling module: postgres_di"


if [[ ${1:-} == "--native" && $have_server -eq 1 ]]; then
    for name in "${suites[@]}"; do
        run "$BEANSC" build "$ROOT/tests/$name.b" -o "$tmp/$name.bin" >/dev/null
        run "$tmp/$name.bin" >"$tmp/$name.native" 2>/dev/null
        # Against the same golden, never the interpreter's fresh output.
        diff -u "$ROOT/tests/$name.out" "$tmp/$name.native"
    done
    echo "ok native: ${#suites[@]} suites match the same goldens"
fi

echo "ok postgres"
