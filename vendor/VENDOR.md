# Vendored: PostgreSQL client library (libpq)

| | |
|---|---|
| upstream | PostgreSQL 18.0 |
| source | https://ftp.postgresql.org/pub/source/v18.0/postgresql-18.0.tar.bz2 |
| archive SHA-256 | `0d5b903b1e5fe361bca7aa9507519933773eb34266b1357c4e7780fdee6d6078` |
| licence | PostgreSQL License (BSD-style) — `postgresql/COPYRIGHT` |
| vendored | 44 `.c` files and 51 headers, at their upstream paths, plus 6 generated headers under `config/` |

## Inventory

### What is here

`vendor/postgresql/` mirrors upstream's own directory shape, so every file
is **byte-identical to the tarball at the same path**. Three exceptions are
marked, and they are the only ones.

| directory | files | why |
|---|---|---|
| `src/interfaces/libpq/` | 15 `.c` + 8 `.h` | libpq's unconditional `OBJS` plus `fe-auth-oauth.c`, which its Makefile compiles into the static library |
| `src/common/` | 20 `.c` + 3 `.h` | every symbol libpq referenced, resolved by linking and reading the undefined list |
| `src/port/` | 9 `.c` | likewise, plus the two `LIBOBJS` replacements below |
| `src/include/` | 40 `.h` | exactly the headers the sources open, found with `clang -H` |

The file set was not guessed. Every `.c` in libpq's `OBJS` was compiled,
then the link was run and each undefined symbol traced to the file that
defines it, until the link succeeded. `tools/` has nothing to re-run: the
result is the `csrc` rows in `beans.pot`.

### Local additions — the only files that are not upstream

Each carries the line `beans relay header — NOT upstream` as its first
comment, and `test.sh` fails if one loses it.

| path | what it is |
|---|---|
| `src/include/pg_config.h` | relay: `#if`s into `config/<os>-<arch>/pg_config.h` |
| `src/include/pg_config_os.h` | relay: same, for the per-OS header `configure` symlinks |
| `src/port/pg_config_paths.h` | relay: same, for the generated install paths |

The real generated headers live under `config/<os>-<arch>/`, one directory
per platform, each produced by a real `configure` run on that platform:

```
./configure --without-openssl --without-gssapi --without-icu \
            --without-readline --without-zlib --without-libxml \
            --without-lz4 --without-zstd
make -C src/port pg_config_paths.h
```

| directory | generated on |
|---|---|
| `config/macos-arm64/` | macOS 15, Apple clang, arm64 |
| `config/linux-aarch64/` | Ubuntu 24.04 in Docker, clang 18, aarch64 |

`config/macos-x86_64/`, `config/linux-x86_64/` and `config/windows-x86_64/`
are **named by the relay headers but not yet committed**. Building for one of
those targets stops at `#error "no committed postgres configuration for this
platform"`, which is the honest answer: a configuration guessed from another
machine is a silent miscompile waiting to happen. Producing one is a
`configure` run on that platform and a `cp`.

### Exclusions, each with its reason

| left out | reason |
|---|---|
| `fe-secure-openssl.c`, `fe-secure-common.c` | `with_ssl=openssl` only. This package builds without OpenSSL, so TLS is not available; `sslmode` above `disable` fails at connect naming the reason. |
| `fe-gssapi-common.c`, `fe-secure-gssapi.c` | GSSAPI/Kerberos pulls krb5 as a second system dependency for a path almost no Beans user reaches. |
| `cryptohash_openssl.c`, `hmac_openssl.c` | the OpenSSL variants of the same functions. Their **non**-OpenSSL twins are vendored instead, which is what lets a TLS-free libpq still authenticate with `scram-sha-256`: OpenSSL is needed for the transport, never for the handshake. |
| `pthread-win32.c`, `win32*.c` | Windows, which has no committed configuration yet. |
| the rest of `src/common` and `src/port` | not referenced. Anything the link did not ask for is not here. |

## Upgrade

1. Download the new tarball and record its SHA-256 in the table above.
2. Replace every vendored `.c` and `.h` from the same upstream path. Do
   **not** overwrite the three relay headers.
3. Re-run `configure` on each platform in the table and replace that
   platform's `config/<os>-<arch>/` files.
4. Compile the set and link it against a program that calls the libpq surface
   this package uses. Add any newly undefined symbol's defining file as a new
   `csrc` row; delete a row whose file upstream removed.
5. `bash tools/regen_sys.sh` to regenerate `sys/sys.b`, and update
   `SKIPPED.md` if the skip list changed.
6. `./test.sh --native` against a server of the matching major version.
