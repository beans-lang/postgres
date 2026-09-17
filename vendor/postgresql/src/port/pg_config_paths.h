/*
 * beans relay header — NOT upstream.
 *
 * Upstream generates pg_config_paths.h with ./configure on the machine that builds
 * libpq. A vendored package has no configure step, so the generated file for
 * each platform is committed under config/<os>-<arch>/ and this header picks
 * one. vendor/VENDOR.md records the exact configure invocation.
 */
#if defined(_WIN32) || defined(_WIN64)
#  include "../../config/windows-x86_64/pg_config_paths.h"
#elif defined(__APPLE__)
#  if defined(__aarch64__) || defined(__arm64__)
#    include "../../config/macos-arm64/pg_config_paths.h"
#  else
#    include "../../config/macos-x86_64/pg_config_paths.h"
#  endif
#elif defined(__linux__)
#  if defined(__aarch64__)
#    include "../../config/linux-aarch64/pg_config_paths.h"
#  else
#    include "../../config/linux-x86_64/pg_config_paths.h"
#  endif
#else
#  error "no committed postgres configuration for this platform — see vendor/VENDOR.md"
#endif
