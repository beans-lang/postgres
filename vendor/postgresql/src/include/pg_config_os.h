/*
 * beans relay header — NOT upstream.
 *
 * Upstream generates pg_config_os.h with ./configure on the machine that builds
 * libpq. A vendored package has no configure step, so the generated file for
 * each platform is committed under config/<os>-<arch>/ and this header picks
 * one. vendor/VENDOR.md records the exact configure invocation.
 */
#if defined(BEANS_POSTGRES_UNCONFIGURED_LIBC)
#  error "postgres has no validated musl configuration -- see vendor/VENDOR.md"
#elif defined(__APPLE__) && defined(__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__) && (defined(__aarch64__) || defined(__arm64__))
#  include "../../config/macos-arm64/pg_config_os.h"
#elif defined(__APPLE__) && defined(__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__) && defined(__x86_64__)
#  include "../../config/macos-x86_64/pg_config_os.h"
#elif defined(__linux__) && defined(__aarch64__)
#  include "../../config/linux-aarch64/pg_config_os.h"
#elif defined(__linux__) && defined(__x86_64__)
#  include "../../config/linux-x86_64/pg_config_os.h"
#elif defined(_WIN32) || defined(_WIN64)
#  error "postgres Windows configuration and port sources are not validated -- see vendor/VENDOR.md"
#else
#  error "no validated postgres configuration for this OS/architecture -- see vendor/VENDOR.md"
#endif
