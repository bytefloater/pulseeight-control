/* PulseEight core: C interface to the shared logic (settings, connection, commands).
 * Implemented in Swift (swift/Sources/PulseEightCoreExports). See docs/core-interface.md.
 *
 * Strings are UTF-8. Every string returned by the library is owned by the caller and must be
 * released with p8_free_string. Unless stated, functions may be called from any thread. */
#ifndef PULSEEIGHT_CORE_H
#define PULSEEIGHT_CORE_H

#include <stdint.h>

#ifdef _WIN32
#define P8_API __declspec(dllimport)
#else
#define P8_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void *p8_core;

/* Called after every change with a JSON snapshot. Runs on a background thread; `snapshot_json`
 * is valid only for the duration of the call. */
typedef void (*p8_observer)(void *context, const char *snapshot_json);

/* Version of this interface; bumped on breaking changes. */
P8_API int32_t p8_abi_version(void);

/* Loads saved settings and begins connecting in the background. */
P8_API p8_core p8_create(void);
P8_API void p8_destroy(p8_core core);

/* Current state as JSON. Free with p8_free_string. */
P8_API char *p8_snapshot(p8_core core);

/* Sends one JSON command and waits for the JSON response. BLOCKS: do not call on the UI thread. */
P8_API char *p8_call(p8_core core, const char *request_json);

/* Registers the change observer (NULL clears it). */
P8_API void p8_set_observer(p8_core core, p8_observer callback, void *context);

P8_API void p8_free_string(char *string);

#ifdef __cplusplus
}
#endif
#endif
