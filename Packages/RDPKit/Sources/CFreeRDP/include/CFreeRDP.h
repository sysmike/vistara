#ifndef CFREERDP_H
#define CFREERDP_H

// Narrow C interface between RDPKit and FreeRDP.
//
// This header deliberately includes no FreeRDP or WinPR headers: Swift sees
// only the functions and opaque types declared here. Every FreeRDP call in
// the implementation is checked against the headers of the pinned version.
//
// A session is not thread-safe. Call all functions for one session from the
// same thread.

#include <stdbool.h>
#include <stdint.h>

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

/// Version of the FreeRDP library this process is linked against, for example
/// "3.33.1". The string has static storage and must not be freed.
const char *vistara_freerdp_version(void);

/// One FreeRDP instance together with its context.
typedef struct vistara_session vistara_session;

/// Allocates a FreeRDP instance and its context. Returns NULL on failure.
/// The caller owns the result and releases it with vistara_session_destroy().
vistara_session *_Nullable vistara_session_create(void);

/// Disconnects if needed, then frees the context and the instance. Passing
/// NULL is allowed.
void vistara_session_destroy(vistara_session *_Nullable session);

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;
    const char *_Nullable domain;
    const char *password;
    uint32_t width;
    uint32_t height;
    /// SHA-256 fingerprint the server's certificate must have, as reported by
    /// vistara_session_presented_fingerprint(). With NULL, a certificate that
    /// OpenSSL cannot verify is always rejected. There is no way to accept a
    /// certificate without naming its fingerprint.
    const char *_Nullable trusted_fingerprint;
} vistara_connect_options;

typedef enum {
    VISTARA_CONNECT_OK = 0,
    /// The server's certificate did not match trusted_fingerprint.
    VISTARA_CONNECT_CERTIFICATE_UNTRUSTED = 1,
    VISTARA_CONNECT_AUTHENTICATION_FAILED = 2,
    /// Anything else; see vistara_session_last_error_name().
    VISTARA_CONNECT_FAILED = 3,
} vistara_connect_result;

/// Connects with Network Level Authentication and blocks until the
/// connection is established or has failed. A session connects at most once.
vistara_connect_result vistara_session_connect(vistara_session *session,
                                               const vistara_connect_options *options);

/// Fingerprint of the certificate the server presented during the last
/// vistara_session_connect(), or NULL if none needed a decision. Owned by the
/// session.
const char *_Nullable vistara_session_presented_fingerprint(const vistara_session *session);

/// FreeRDP's name for the last error, for example
/// "FREERDP_ERROR_AUTHENTICATION_FAILED". Static storage.
const char *vistara_session_last_error_name(const vistara_session *session);

/// Waits up to timeout_ms for network activity and processes it. Returns
/// false once the session is disconnected.
bool vistara_session_poll(vistara_session *session, uint32_t timeout_ms);

/// Framebuffer geometry and pixels (32-bit BGRA, rows of `stride` bytes).
/// Valid while connected; the buffer may move when the desktop is resized.
uint32_t vistara_session_width(const vistara_session *session);
uint32_t vistara_session_height(const vistara_session *session);
uint32_t vistara_session_stride(const vistara_session *session);
const uint8_t *_Nullable vistara_session_framebuffer(const vistara_session *session);

/// Number of paint cycles that changed the framebuffer since connecting.
uint64_t vistara_session_paint_count(const vistara_session *session);

/// Disconnects. Does nothing if not connected.
void vistara_session_disconnect(vistara_session *session);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#endif
