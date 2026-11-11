#include "CFreeRDP.h"

#include <stdlib.h>
#include <string.h>

#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <winpr/synch.h>

struct vistara_session {
    freerdp *instance;
    bool connect_attempted;
    bool connected;
    bool certificate_rejected;
    vistara_certificate_decider decide_certificate;
    void *decide_certificate_context;
    uint64_t paint_count;
};

// FreeRDP allocates ContextSize bytes and treats the start as rdpContext, so
// the session pointer rides along behind it.
typedef struct {
    rdpContext base;
    vistara_session *session;
} vistara_context;

static vistara_session *session_of(rdpContext *context) {
    return ((vistara_context *)context)->session;
}

const char *vistara_freerdp_version(void) {
    return freerdp_get_version_string();
}

// MARK: Certificates

/// Asks the decider. Acceptance is for this session only, so nothing is
/// written to FreeRDP's own certificate store.
static DWORD decide_certificate(vistara_session *session, const vistara_certificate *certificate) {
    if (session->decide_certificate && certificate->fingerprint &&
        session->decide_certificate(session->decide_certificate_context, certificate)) {
        return 2; // accept for this session only
    }
    session->certificate_rejected = true;
    return 0;
}

static const char *or_empty(const char *text) {
    return text ? text : "";
}

static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                const char *common_name, const char *subject, const char *issuer,
                                const char *fingerprint, DWORD flags) {
    (void)flags;
    const vistara_certificate certificate = {
        .host = or_empty(host),
        .port = port,
        .common_name = or_empty(common_name),
        .subject = or_empty(subject),
        .issuer = or_empty(issuer),
        .fingerprint = fingerprint,
        .previous_fingerprint = NULL,
    };
    return decide_certificate(session_of(instance->context), &certificate);
}

static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                        const char *common_name, const char *subject,
                                        const char *issuer, const char *new_fingerprint,
                                        const char *old_subject, const char *old_issuer,
                                        const char *old_fingerprint, DWORD flags) {
    (void)old_subject, (void)old_issuer, (void)flags;
    const vistara_certificate certificate = {
        .host = or_empty(host),
        .port = port,
        .common_name = or_empty(common_name),
        .subject = or_empty(subject),
        .issuer = or_empty(issuer),
        .fingerprint = new_fingerprint,
        .previous_fingerprint = or_empty(old_fingerprint),
    };
    return decide_certificate(session_of(instance->context), &certificate);
}

// MARK: Painting

static BOOL begin_paint(rdpContext *context) {
    HGDI_WND window = context->gdi->primary->hdc->hwnd;
    window->invalid->null = TRUE;
    window->ninvalid = 0;
    return TRUE;
}

static BOOL end_paint(rdpContext *context) {
    HGDI_WND window = context->gdi->primary->hdc->hwnd;
    if (!window->invalid->null) {
        session_of(context)->paint_count += 1;
    }
    return TRUE;
}

static BOOL desktop_resize(rdpContext *context) {
    rdpSettings *settings = context->settings;
    return gdi_resize(context->gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                      freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
}

// MARK: Connection callbacks

static BOOL pre_connect(freerdp *instance) {
    (void)instance;
    return TRUE;
}

static BOOL post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        return FALSE;
    }
    rdpUpdate *update = instance->context->update;
    update->BeginPaint = begin_paint;
    update->EndPaint = end_paint;
    update->DesktopResize = desktop_resize;
    return TRUE;
}

static void post_disconnect(freerdp *instance) {
    gdi_free(instance);
}

// MARK: Lifecycle

vistara_session *vistara_session_create(void) {
    vistara_session *session = calloc(1, sizeof(*session));
    if (!session) {
        return NULL;
    }

    session->instance = freerdp_new();
    if (!session->instance) {
        free(session);
        return NULL;
    }

    freerdp *instance = session->instance;
    instance->ContextSize = sizeof(vistara_context);
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->VerifyCertificateEx = verify_certificate;
    instance->VerifyChangedCertificateEx = verify_changed_certificate;

    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        free(session);
        return NULL;
    }
    ((vistara_context *)instance->context)->session = session;
    return session;
}

void vistara_session_destroy(vistara_session *session) {
    if (!session) {
        return;
    }
    vistara_session_disconnect(session);
    freerdp_context_free(session->instance);
    freerdp_free(session->instance);
    free(session);
}

static bool apply_options(rdpSettings *settings, const vistara_connect_options *options) {
    return freerdp_settings_set_string(settings, FreeRDP_ServerHostname, options->host) &&
           freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, options->port) &&
           freerdp_settings_set_string(settings, FreeRDP_Username, options->username) &&
           freerdp_settings_set_string(settings, FreeRDP_Domain, options->domain) &&
           freerdp_settings_set_string(settings, FreeRDP_Password, options->password) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, options->width) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, options->height) &&
           freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, options->scale_percent) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, 100) &&
           // Network Level Authentication, or TLS when the caller allows it.
           // Legacy RDP security is never offered.
           freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, options->require_nla ? FALSE : TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE);
}

vistara_connect_result vistara_session_connect(vistara_session *session,
                                               const vistara_connect_options *options) {
    if (session->connect_attempted) {
        return VISTARA_CONNECT_FAILED;
    }
    session->connect_attempted = true;

    session->decide_certificate = options->decide_certificate;
    session->decide_certificate_context = options->decide_certificate_context;
    if (!apply_options(session->instance->context->settings, options)) {
        return VISTARA_CONNECT_FAILED;
    }

    if (freerdp_connect(session->instance)) {
        session->connected = true;
        return VISTARA_CONNECT_OK;
    }

    if (session->certificate_rejected) {
        return VISTARA_CONNECT_CERTIFICATE_UNTRUSTED;
    }
    switch (freerdp_get_last_error(session->instance->context)) {
    case FREERDP_ERROR_CONNECT_CANCELLED:
        return VISTARA_CONNECT_CANCELLED;
    case FREERDP_ERROR_AUTHENTICATION_FAILED:
    case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        return VISTARA_CONNECT_AUTHENTICATION_FAILED;
    default:
        return VISTARA_CONNECT_FAILED;
    }
}

void vistara_session_abort(vistara_session *session) {
    (void)freerdp_abort_connect_context(session->instance->context);
}

const char *vistara_session_last_error_name(const vistara_session *session) {
    return freerdp_get_last_error_name(freerdp_get_last_error(session->instance->context));
}

bool vistara_session_poll(vistara_session *session, uint32_t timeout_ms) {
    if (!session->connected) {
        return false;
    }
    rdpContext *context = session->instance->context;

    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {0};
    DWORD count = freerdp_get_event_handles(context, handles, MAXIMUM_WAIT_OBJECTS);
    if (count == 0) {
        return false;
    }
    if (WaitForMultipleObjects(count, handles, FALSE, timeout_ms) == WAIT_FAILED) {
        return false;
    }
    if (!freerdp_check_event_handles(context)) {
        return false;
    }
    return !freerdp_shall_disconnect_context(context);
}

static const rdpGdi *gdi_of(const vistara_session *session) {
    return session->connected ? session->instance->context->gdi : NULL;
}

uint32_t vistara_session_width(const vistara_session *session) {
    const rdpGdi *gdi = gdi_of(session);
    return gdi ? (uint32_t)gdi->width : 0;
}

uint32_t vistara_session_height(const vistara_session *session) {
    const rdpGdi *gdi = gdi_of(session);
    return gdi ? (uint32_t)gdi->height : 0;
}

uint32_t vistara_session_stride(const vistara_session *session) {
    const rdpGdi *gdi = gdi_of(session);
    return gdi ? gdi->stride : 0;
}

const uint8_t *vistara_session_framebuffer(const vistara_session *session) {
    const rdpGdi *gdi = gdi_of(session);
    return gdi ? gdi->primary_buffer : NULL;
}

uint64_t vistara_session_paint_count(const vistara_session *session) {
    return session->paint_count;
}

void vistara_session_disconnect(vistara_session *session) {
    if (!session->connected) {
        return;
    }
    session->connected = false;
    (void)freerdp_disconnect(session->instance);
}
