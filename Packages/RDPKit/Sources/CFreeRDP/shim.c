#include "CFreeRDP.h"
#include "probe.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <pthread.h>
#include <stdatomic.h>

#include <freerdp/addin.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/codec/color.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/transport_io.h>
#include <freerdp/update.h>
#include <winpr/cast.h>
#include <winpr/handle.h>
#include <winpr/synch.h>

struct vistara_session {
    freerdp *instance;
    // FreeRDP's own TCP connect, which tcp_connect() wraps.
    pTCPConnect default_tcp_connect;
    int tcp_os_error;
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
    // The display control channel, once the server has opened it and stated
    // its limits. Owned by FreeRDP, and announced on whichever thread FreeRDP
    // runs the channel on, hence atomic.
    _Atomic(DispClientContext *) display_control;
    atomic_bool display_control_ready;
    // A size asked for that has not been sent yet: the channel comes up a few
    // round trips after connecting, and a request made before that must not
    // be lost. Session thread only.
    bool has_pending_size;
    uint32_t pending_width, pending_height, pending_scale_percent;
    // The cursor the server asked for last, as a copy this session owns.
    bool cursor_changed;
    vistara_cursor_kind cursor_kind;
    uint8_t *cursor_pixels;
    uint32_t cursor_width, cursor_height, cursor_hotspot_x, cursor_hotspot_y;
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

/// FreeRDP hands every server certificate here, because certificate
/// management is declared external in apply_options(). The result is for
/// this connection only; FreeRDP stores nothing.
static int verify_x509_certificate(freerdp *instance, const BYTE *data, size_t length,
                                   const char *hostname, UINT16 port, DWORD flags) {
    (void)flags;
    vistara_session *session = session_of(instance->context);
    const vistara_certificate certificate = {
        .host = hostname ? hostname : "",
        .port = port,
        .pem = (const char *)data,
        .pem_length = length,
    };
    if (data && length > 0 && session->decide_certificate &&
        session->decide_certificate(session->decide_certificate_context, &certificate)) {
        return 2; // accept for this session only
    }
    session->certificate_rejected = true;
    return 0;
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

// MARK: Cursor

// Larger than any pointer RDP defines (384 with the large pointer capability).
#define VISTARA_MAX_CURSOR_SIDE 512u

// FreeRDP allocates `size` bytes per pointer, so the decoded pixels ride
// along behind its own fields.
typedef struct {
    rdpPointer base;
    uint8_t *pixels;
} vistara_pointer;

static BOOL pointer_new(rdpContext *context, rdpPointer *pointer) {
    vistara_pointer *own = (vistara_pointer *)pointer;
    const uint32_t width = pointer->width;
    const uint32_t height = pointer->height;
    if (width == 0 || height == 0 || width > VISTARA_MAX_CURSOR_SIDE ||
        height > VISTARA_MAX_CURSOR_SIDE || !context->gdi) {
        return FALSE;
    }
    own->pixels = calloc((size_t)width * height, 4);
    if (!own->pixels) {
        return FALSE;
    }
    if (!freerdp_image_copy_from_pointer_data(own->pixels, PIXEL_FORMAT_BGRA32, width * 4, 0, 0,
                                              width, height, pointer->xorMaskData,
                                              pointer->lengthXorMask, pointer->andMaskData,
                                              pointer->lengthAndMask, pointer->xorBpp,
                                              &context->gdi->palette)) {
        free(own->pixels);
        own->pixels = NULL;
        return FALSE;
    }
    return TRUE;
}

static void pointer_free(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    vistara_pointer *own = (vistara_pointer *)pointer;
    free(own->pixels);
    own->pixels = NULL;
}

static BOOL pointer_set(rdpContext *context, rdpPointer *pointer) {
    vistara_session *session = session_of(context);
    const vistara_pointer *own = (const vistara_pointer *)pointer;
    if (!own->pixels) {
        return FALSE;
    }
    // A copy, because FreeRDP may free the pointer before Swift has read it.
    const size_t length = (size_t)pointer->width * pointer->height * 4;
    uint8_t *copy = malloc(length);
    if (!copy) {
        return FALSE;
    }
    memcpy(copy, own->pixels, length);
    free(session->cursor_pixels);
    session->cursor_pixels = copy;
    session->cursor_width = pointer->width;
    session->cursor_height = pointer->height;
    session->cursor_hotspot_x = pointer->xPos < pointer->width ? pointer->xPos : pointer->width - 1;
    session->cursor_hotspot_y = pointer->yPos < pointer->height ? pointer->yPos : pointer->height - 1;
    session->cursor_kind = VISTARA_CURSOR_IMAGE;
    session->cursor_changed = true;
    return TRUE;
}

static BOOL pointer_set_kind(rdpContext *context, vistara_cursor_kind kind) {
    vistara_session *session = session_of(context);
    session->cursor_kind = kind;
    session->cursor_changed = true;
    return TRUE;
}

static BOOL pointer_set_null(rdpContext *context) {
    return pointer_set_kind(context, VISTARA_CURSOR_HIDDEN);
}

static BOOL pointer_set_default(rdpContext *context) {
    return pointer_set_kind(context, VISTARA_CURSOR_DEFAULT);
}

static BOOL pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    // The server moving the pointer is not followed: the Mac's pointer stays
    // where the user put it.
    (void)context, (void)x, (void)y;
    return TRUE;
}

static void register_pointer(rdpContext *context) {
    rdpPointer prototype = {0};
    prototype.size = sizeof(vistara_pointer);
    prototype.New = pointer_new;
    prototype.Free = pointer_free;
    prototype.Set = pointer_set;
    prototype.SetNull = pointer_set_null;
    prototype.SetDefault = pointer_set_default;
    prototype.SetPosition = pointer_set_position;
    graphics_register_pointer(context->graphics, &prototype);
}

bool vistara_session_take_cursor(vistara_session *session, vistara_cursor *cursor) {
    if (!session->cursor_changed) {
        return false;
    }
    session->cursor_changed = false;
    const bool is_image = session->cursor_kind == VISTARA_CURSOR_IMAGE && session->cursor_pixels;
    cursor->kind = is_image || session->cursor_kind != VISTARA_CURSOR_IMAGE ? session->cursor_kind
                                                                           : VISTARA_CURSOR_DEFAULT;
    cursor->width = is_image ? session->cursor_width : 0;
    cursor->height = is_image ? session->cursor_height : 0;
    cursor->hotspot_x = is_image ? session->cursor_hotspot_x : 0;
    cursor->hotspot_y = is_image ? session->cursor_hotspot_y : 0;
    cursor->pixels = is_image ? session->cursor_pixels : NULL;
    return true;
}

// MARK: Channels

// Vistara loads exactly the channels it uses instead of FreeRDP's general
// loader, which adds several more depending on defaults. So far that is
// display control, which is a dynamic channel and needs drdynvc to carry it.

static pthread_once_t addin_provider_once = PTHREAD_ONCE_INIT;

static void register_addin_provider(void) {
    // Channels are compiled into libfreerdp-client; this tells FreeRDP to
    // look for them there.
    (void)freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);
}

static BOOL load_channels(freerdp *instance) {
    rdpContext *context = instance->context;
    const char *const display_control[] = {DISP_CHANNEL_NAME};
    if (!freerdp_client_add_dynamic_channel(context->settings, 1, display_control) ||
        !freerdp_settings_set_bool(context->settings, FreeRDP_SupportDynamicChannels, TRUE)) {
        return FALSE;
    }
    PVIRTUALCHANNELENTRY entry = freerdp_load_channel_addin_entry(
        DRDYNVC_SVC_CHANNEL_NAME, NULL, NULL,
        FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    if (!entry) {
        return FALSE;
    }
    return freerdp_channels_client_load_ex(context->channels, context->settings,
                                           WINPR_FUNC_PTR_CAST(entry, PVIRTUALCHANNELENTRYEX),
                                           context->settings) == 0;
}

static UINT display_control_caps(DispClientContext *display_control, UINT32 max_monitors,
                                 UINT32 area_factor_a, UINT32 area_factor_b) {
    (void)max_monitors, (void)area_factor_a, (void)area_factor_b;
    vistara_session *session = display_control->custom;
    if (session) {
        atomic_store(&session->display_control_ready, true);
        // The session thread sends what is waiting.
        vistara_session_wake(session);
    }
    return CHANNEL_RC_OK;
}

static void channel_connected(void *context, const ChannelConnectedEventArgs *event) {
    vistara_session *session = session_of(context);
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0 && event->pInterface) {
        DispClientContext *display_control = event->pInterface;
        display_control->custom = session;
        display_control->DisplayControlCaps = display_control_caps;
        atomic_store(&session->display_control, display_control);
    }
}

static void channel_disconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    vistara_session *session = session_of(context);
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        atomic_store(&session->display_control_ready, false);
        atomic_store(&session->display_control, NULL);
    }
}

/// Sends the size that is waiting, if the channel is ready for it.
static void send_pending_size(vistara_session *session) {
    DispClientContext *display_control = atomic_load(&session->display_control);
    if (!session->has_pending_size || !session->connected || !display_control ||
        !atomic_load(&session->display_control_ready)) {
        return;
    }
    session->has_pending_size = false;

    const uint32_t scale_percent = session->pending_scale_percent;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = {0};
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = session->pending_width;
    layout.Height = session->pending_height;
    // Millimetres, as if the desktop were shown at 96 points per inch.
    layout.PhysicalWidth = (UINT32)((uint64_t)layout.Width * 2540 / ((uint64_t)96 * scale_percent));
    layout.PhysicalHeight = (UINT32)((uint64_t)layout.Height * 2540 / ((uint64_t)96 * scale_percent));
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = scale_percent;
    layout.DeviceScaleFactor = 100;
    (void)display_control->SendMonitorLayout(display_control, 1, &layout);
}

bool vistara_session_request_size(vistara_session *session, uint32_t width, uint32_t height,
                                  uint32_t scale_percent) {
    if (!session->connected) {
        return false;
    }
    if (scale_percent < 100) scale_percent = 100;
    if (scale_percent > 500) scale_percent = 500;
    session->has_pending_size = true;
    session->pending_width = width;
    session->pending_height = height;
    session->pending_scale_percent = scale_percent;
    send_pending_size(session);
    return true;
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
    register_pointer(instance->context);
    return TRUE;
}

static void post_disconnect(freerdp *instance) {
    gdi_free(instance);
}

// MARK: Errors

/// How long a diagnostic connection may take, in milliseconds.
#define VISTARA_PROBE_TIMEOUT_MS 2000

/// Calls FreeRDP's TCP connect and works out why it failed, because FreeRDP
/// reports every failure to connect as FREERDP_ERROR_CONNECT_FAILED and
/// closes the socket, and with it the error, before returning.
///
/// An attempt that used up the whole timeout was not answered. One that
/// failed sooner is repeated once, briefly, to learn whether it was refused
/// or found no route.
static int tcp_connect(rdpContext *context, rdpSettings *settings, const char *hostname, int port,
                       DWORD timeout) {
    vistara_session *session = session_of(context);
    const uint64_t started = vistara_monotonic_ms();
    const int socket = session->default_tcp_connect(context, settings, hostname, port, timeout);
    if (socket >= 0 || freerdp_get_last_error(context) != FREERDP_ERROR_CONNECT_FAILED || !hostname) {
        return socket;
    }
    const uint64_t elapsed = vistara_monotonic_ms() - started;
    if (timeout > 0 && timeout != INFINITE && elapsed + 500 >= timeout) {
        session->tcp_os_error = ETIMEDOUT;
    } else {
        session->tcp_os_error = vistara_probe_tcp_error(hostname, port, VISTARA_PROBE_TIMEOUT_MS);
    }
    return socket;
}

static bool wrap_tcp_connect(vistara_session *session) {
    rdpContext *context = session->instance->context;
    const rdpTransportIo *io = freerdp_get_io_callbacks(context);
    if (!io || !io->TCPConnect) {
        return false;
    }
    rdpTransportIo wrapped = *io;
    session->default_tcp_connect = io->TCPConnect;
    wrapped.TCPConnect = tcp_connect;
    return freerdp_set_io_callbacks(context, &wrapped);
}

uint32_t vistara_session_last_error_code(const vistara_session *session) {
    return freerdp_get_last_error(session->instance->context);
}

int32_t vistara_probe_connection(const char *hostname, uint16_t port, int32_t timeout_ms) {
    return vistara_probe_tcp_error(hostname, port, timeout_ms);
}

int32_t vistara_session_last_os_error(const vistara_session *session) {
    return session->tcp_os_error;
}

const char *vistara_error_name(uint32_t code) {
    const char *name = freerdp_get_last_error_name(code);
    return name ? name : "";
}

const char *vistara_error_description(uint32_t code) {
    const char *description = freerdp_get_last_error_string(code);
    return description ? description : "";
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
    instance->VerifyX509Certificate = verify_x509_certificate;
    instance->LoadChannels = load_channels;
    (void)pthread_once(&addin_provider_once, register_addin_provider);

    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        (void)CloseHandle(session->wake_event);
        free(session);
        return NULL;
    }
    ((vistara_context *)instance->context)->session = session;
    if (!wrap_tcp_connect(session) ||
        PubSub_SubscribeChannelConnected(instance->context->pubSub, channel_connected) < 0 ||
        PubSub_SubscribeChannelDisconnected(instance->context->pubSub, channel_disconnected) < 0) {
        vistara_session_destroy(session);
        return NULL;
    }
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
    free(session->cursor_pixels);
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
           freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
           // Certificates are judged by the application alone: the system's
           // trust evaluation and Vistara's own trust store. FreeRDP's
           // known-hosts file is neither read nor written.
           freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement, TRUE) &&
           // Offered to the server; each is used only if the server has it too.
           // The desktop may change size while connected.
           freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_HasHorizontalWheel, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_HasExtendedMouseEvent, TRUE);
}

vistara_connect_result vistara_session_connect(vistara_session *session,
                                               const vistara_connect_options *options) {
    if (session->connect_attempted) {
        return VISTARA_CONNECT_FAILED;
    }
    session->connect_attempted = true;
    session->tcp_os_error = 0;

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
    send_pending_size(session);
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

bool vistara_session_send_pointer_move(vistara_session *session, uint16_t x, uint16_t y) {
    if (!session->connected) {
        return false;
    }
    return freerdp_input_send_mouse_event(session->instance->context->input, PTR_FLAGS_MOVE, x, y);
}

bool vistara_session_send_pointer_button(vistara_session *session, uint8_t button, bool down,
                                         uint16_t x, uint16_t y) {
    if (!session->connected) {
        return false;
    }
    rdpInput *input = session->instance->context->input;
    switch (button) {
    case 0:
        return freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON1 | (down ? PTR_FLAGS_DOWN : 0), x, y);
    case 1:
        return freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON2 | (down ? PTR_FLAGS_DOWN : 0), x, y);
    case 2:
        return freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON3 | (down ? PTR_FLAGS_DOWN : 0), x, y);
    case 3:
        return freerdp_input_send_extended_mouse_event(
            input, PTR_XFLAGS_BUTTON1 | (down ? PTR_XFLAGS_DOWN : 0), x, y);
    case 4:
        return freerdp_input_send_extended_mouse_event(
            input, PTR_XFLAGS_BUTTON2 | (down ? PTR_XFLAGS_DOWN : 0), x, y);
    default:
        return false;
    }
}

bool vistara_session_send_wheel(vistara_session *session, bool horizontal, int16_t rotation,
                                uint16_t x, uint16_t y) {
    if (!session->connected || rotation == 0) {
        return false;
    }
    if (rotation > 255) rotation = 255;
    if (rotation < -255) rotation = -255;
    // The rotation is a 9-bit two's complement number whose sign bit is
    // PTR_FLAGS_WHEEL_NEGATIVE.
    UINT16 flags = (horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL) |
                   ((UINT16)rotation & (WheelRotationMask));
    return freerdp_input_send_mouse_event(session->instance->context->input, flags, x, y);
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
