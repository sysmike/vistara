#include "CFreeRDP.h"

#include <stdlib.h>
#include <string.h>

#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <winpr/handle.h>
#include <winpr/synch.h>

struct vistara_session {
    freerdp *instance;
    // Signalled by vistara_session_wake() to end a poll early.
    HANDLE wake_event;
    bool connect_attempted;
    bool connected;
    bool certificate_rejected;
    vistara_certificate_decider decide_certificate;
    void *decide_certificate_context;
    uint64_t paint_count;
    // Union of everything painted since the last vistara_session_take_dirty().
    bool has_dirty;
    int32_t dirty_left, dirty_top, dirty_right, dirty_bottom;
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

static void add_dirty(vistara_session *session, int32_t x, int32_t y, int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) {
        return;
    }
    if (!session->has_dirty) {
        session->has_dirty = true;
        session->dirty_left = x;
        session->dirty_top = y;
        session->dirty_right = x + width;
        session->dirty_bottom = y + height;
        return;
    }
    if (x < session->dirty_left) session->dirty_left = x;
    if (y < session->dirty_top) session->dirty_top = y;
    if (x + width > session->dirty_right) session->dirty_right = x + width;
    if (y + height > session->dirty_bottom) session->dirty_bottom = y + height;
}

static BOOL begin_paint(rdpContext *context) {
    HGDI_WND window = context->gdi->primary->hdc->hwnd;
    window->invalid->null = TRUE;
    window->ninvalid = 0;
    return TRUE;
}

static BOOL end_paint(rdpContext *context) {
    HGDI_WND window = context->gdi->primary->hdc->hwnd;
    const GDI_RGN *invalid = window->invalid;
    if (!invalid->null) {
        vistara_session *session = session_of(context);
        session->paint_count += 1;
        add_dirty(session, invalid->x, invalid->y, invalid->w, invalid->h);
    }
    return TRUE;
}

static BOOL desktop_resize(rdpContext *context) {
    rdpSettings *settings = context->settings;
    if (!gdi_resize(context->gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                    freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight))) {
        return FALSE;
    }
    add_dirty(session_of(context), 0, 0, context->gdi->width, context->gdi->height);
    return TRUE;
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

    session->wake_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!session->wake_event) {
        free(session);
        return NULL;
    }
    session->instance = freerdp_new();
    if (!session->instance) {
        (void)CloseHandle(session->wake_event);
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
        (void)CloseHandle(session->wake_event);
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
    (void)CloseHandle(session->wake_event);
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

    // One slot is kept for the wake event.
    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {0};
    DWORD count = freerdp_get_event_handles(context, handles, MAXIMUM_WAIT_OBJECTS - 1);
    if (count == 0) {
        return false;
    }
    handles[count++] = session->wake_event;
    if (WaitForMultipleObjects(count, handles, FALSE, timeout_ms) == WAIT_FAILED) {
        return false;
    }
    (void)ResetEvent(session->wake_event);
    if (!freerdp_check_event_handles(context)) {
        return false;
    }
    return !freerdp_shall_disconnect_context(context);
}

void vistara_session_wake(vistara_session *session) {
    (void)SetEvent(session->wake_event);
}

// MARK: Input

bool vistara_session_send_key(vistara_session *session, uint8_t code, bool extended, bool down) {
    if (!session->connected) {
        return false;
    }
    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    if (extended) {
        flags |= KBD_FLAGS_EXTENDED;
    }
    return freerdp_input_send_keyboard_event(session->instance->context->input, flags, code);
}

bool vistara_session_send_lock_state(vistara_session *session, bool caps_lock, bool num_lock,
                                     bool scroll_lock) {
    if (!session->connected) {
        return false;
    }
    UINT32 flags = 0;
    if (caps_lock) flags |= KBD_SYNC_CAPS_LOCK;
    if (num_lock) flags |= KBD_SYNC_NUM_LOCK;
    if (scroll_lock) flags |= KBD_SYNC_SCROLL_LOCK;
    return freerdp_input_send_synchronize_event(session->instance->context->input, flags);
}

// MARK: Framebuffer

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

bool vistara_session_take_dirty(vistara_session *session, vistara_rect *rect) {
    const rdpGdi *gdi = gdi_of(session);
    if (!gdi || !session->has_dirty) {
        return false;
    }
    session->has_dirty = false;

    // Clip to the framebuffer; a server may report more than is there.
    int32_t left = session->dirty_left < 0 ? 0 : session->dirty_left;
    int32_t top = session->dirty_top < 0 ? 0 : session->dirty_top;
    int32_t right = session->dirty_right > gdi->width ? gdi->width : session->dirty_right;
    int32_t bottom = session->dirty_bottom > gdi->height ? gdi->height : session->dirty_bottom;
    if (right <= left || bottom <= top) {
        return false;
    }
    rect->x = left;
    rect->y = top;
    rect->width = right - left;
    rect->height = bottom - top;
    return true;
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
