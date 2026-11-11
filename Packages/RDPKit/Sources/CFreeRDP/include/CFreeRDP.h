#ifndef CFREERDP_H
#define CFREERDP_H

// Narrow C interface between RDPKit and FreeRDP.
//
// This header deliberately includes no FreeRDP or WinPR headers: Swift sees
// only the functions and opaque types declared here. Every FreeRDP call in
// the implementation is checked against the headers of the pinned version.

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

/// Frees the context and the instance. Passing NULL is allowed.
void vistara_session_destroy(vistara_session *_Nullable session);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#endif
