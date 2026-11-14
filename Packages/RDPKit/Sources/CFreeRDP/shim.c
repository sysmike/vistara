#include "CFreeRDP.h"
#include "audio.h"
#include "clipboard_files.h"
#include "drive.h"
#include "printer.h"
#include "monitors.h"
#include "probe.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <winpr/sysinfo.h>
#include <pthread.h>
#include <stdatomic.h>

#include <freerdp/addin.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/rdpsnd.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
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
#include <winpr/string.h>
#include <winpr/user.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>

/// The remote computer's clipboard data asked for: an answer does not say
/// which format it holds.
typedef enum {
    VISTARA_AWAITING_NOTHING,
    VISTARA_AWAITING_TEXT,
    VISTARA_AWAITING_FILE_LIST,
} vistara_awaiting;

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
    vistara_gateway_message_decider decide_gateway_message;
    void *decide_gateway_message_context;
    // Whether the connection goes through a gateway, and whether it got past
    // it: a certificate other than the gateway's was seen.
    bool uses_gateway;
    bool reached_computer;
    uint64_t paint_count;
    // Union of everything painted since the last vistara_session_take_dirty().
    bool has_dirty;
    int32_t dirty_left, dirty_top, dirty_right, dirty_bottom;
    // The display control channel, once the server has opened it and stated
    // its limits. Owned by FreeRDP, and announced on whichever thread FreeRDP
    // runs the channel on, hence atomic.
    _Atomic(DispClientContext *) display_control;
    atomic_bool display_control_ready;
    // The clipboard channel. Its handlers may run on another thread than the
    // session's, so everything below is guarded by clipboard_lock.
    pthread_mutex_t clipboard_lock;
    CliprdrClientContext *clipboard;
    bool share_clipboard;
    // Files too: share_clipboard and the connection's copy_files.
    bool copy_files;
    bool clipboard_ready;
    bool clipboard_ever_connected;
    // The server's general clipboard capability flags.
    uint32_t server_clipboard_flags;
    // What the last format data request asked for, and whether text was
    // offered along with the files, to ask for once the list is in.
    vistara_awaiting awaiting;
    bool text_after_files;
    vistara_clipboard_files files;
    // This Mac's text as UTF-16LE with a terminating zero, for when the remote
    // computer asks for it.
    WCHAR *local_text;
    size_t local_text_bytes;
    // The remote computer's latest text, UTF-8, until taken.
    char *remote_text;
    uint64_t clipboard_bytes_sent;
    // Load the sound channel and play its sound on this Mac.
    bool play_audio_here;
    // The sound channel's arguments, which it reads when it connects.
    ADDIN_ARGV *audio_args;
    vistara_audio_stats audio;
    // How many folders are shared, and the paths of those shared read-only.
    size_t shared_folder_count;
    char **read_only_paths;
    size_t read_only_count;
    // What the remote computer prints, and the id its printer device carries.
    vistara_print_spool *print_spool;
    uint32_t printer_id;
    // A size asked for that has not been sent yet: the channel comes up a few
    // round trips after connecting, and a request made before that must not
    // be lost. Session thread only.
    bool has_pending_size;
    // A Suppress Output waiting to be sent (send_pending_display_updates).
    bool has_pending_display_updates;
    bool pending_display_updates_allowed;
    // Whether the server was last told to send pictures, as it does unless told.
    bool server_sends_pictures;
    // When the server last started activating the connection, and whether a
    // picture came since it was done.
    uint64_t activation_started;
    bool painted_since_activation;
    // The layout of one or more monitors waiting with has_pending_size.
    vistara_monitor pending_monitors[VISTARA_MAX_MONITORS];
    size_t pending_monitor_count;
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

// MARK: Logging

static vistara_log_sink log_sink = NULL;

static BOOL log_message(const wLogMessage *message) {
    vistara_log_sink sink = log_sink;
    if (sink && message && message->TextString) {
        sink(message->Level, message->FunctionName ? message->FunctionName : "", message->TextString);
    }
    return TRUE;
}

// Raw data, images, and packets may hold anything, credentials included.
static BOOL log_dropped(const wLogMessage *message) {
    (void)message;
    return TRUE;
}

void vistara_logging_install(vistara_log_sink sink, uint32_t level) {
    log_sink = sink;
    wLog *root = WLog_GetRoot();
    if (!root) {
        return;
    }
    (void)WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK);
    wLogAppender *appender = WLog_GetLogAppender(root);
    if (appender) {
        wLogCallbacks callbacks = {
            .data = log_dropped, .image = log_dropped, .message = log_message, .package = log_dropped};
        (void)WLog_ConfigureAppender(appender, "callbacks", &callbacks);
    }
    (void)WLog_SetLogLevel(root, level);
}

void vistara_logging_set_level(uint32_t level) {
    wLog *root = WLog_GetRoot();
    if (root) {
        (void)WLog_SetLogLevel(root, level);
    }
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
    vistara_session *session = session_of(instance->context);
    const bool is_gateway = (flags & VERIFY_CERT_FLAG_GATEWAY) != 0;
    if (!is_gateway) {
        session->reached_computer = true;
    }
    const vistara_certificate certificate = {
        .host = hostname ? hostname : "",
        .port = port,
        .pem = (const char *)data,
        .pem_length = length,
        .is_gateway = is_gateway,
    };
    if (data && length > 0 && session->decide_certificate &&
        session->decide_certificate(session->decide_certificate_context, &certificate)) {
        return 2; // accept for this session only
    }
    session->certificate_rejected = true;
    return 0;
}

// MARK: Gateway

/// What the gateway shows before connecting ([MS-TSGU] 2.2.10.14). `length`
/// is in bytes of UTF-16. Without a decider, a notice is accepted and consent
/// declined.
static BOOL present_gateway_message(freerdp *instance, UINT32 type, BOOL is_display_mandatory,
                                    BOOL is_consent_mandatory, size_t length, const WCHAR *message) {
    vistara_session *session = session_of(instance->context);
    const bool is_consent = type == GATEWAY_MESSAGE_CONSENT;
    const bool requires_consent = is_consent_mandatory || is_consent;
    if (!session->decide_gateway_message) {
        return requires_consent ? FALSE : TRUE;
    }
    const uint16_t empty = 0;
    const uint16_t *text = message ? (const uint16_t *)message : &empty;
    const size_t units = message ? length / sizeof(WCHAR) : 0;
    return session->decide_gateway_message(session->decide_gateway_message_context, is_consent,
                                           is_display_mandatory, requires_consent, text, units)
               ? TRUE
               : FALSE;
}

/// The gateway, or none. Only the HTTP transport, over WebSocket where the
/// gateway offers it: never RPC over HTTP (Windows Server 2008) or UDP.
static bool apply_gateway(rdpSettings *settings, const vistara_connect_options *options) {
    if (!options->gateway_host) {
        return freerdp_set_gateway_usage_method(settings, TSC_PROXY_MODE_NONE_DIRECT);
    }
    const bool same = options->gateway_same_credentials;
    return freerdp_set_gateway_usage_method(settings, TSC_PROXY_MODE_DIRECT) &&
           freerdp_settings_set_string(settings, FreeRDP_GatewayHostname, options->gateway_host) &&
           freerdp_settings_set_uint32(settings, FreeRDP_GatewayPort, options->gateway_port) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, same) &&
           freerdp_settings_set_string(settings, FreeRDP_GatewayUsername,
                                       same ? options->username : options->gateway_username) &&
           freerdp_settings_set_string(settings, FreeRDP_GatewayDomain,
                                       same ? options->domain : options->gateway_domain) &&
           freerdp_settings_set_string(settings, FreeRDP_GatewayPassword,
                                       same ? options->password : options->gateway_password) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpTransport, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpUseWebsockets, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayRpcTransport, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayUdpTransport, FALSE);
}

bool vistara_session_failed_at_gateway(const vistara_session *session) {
    return session->uses_gateway && !session->reached_computer;
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
        if (freerdp_get_state(context) == CONNECTION_STATE_ACTIVE) {
            session->painted_since_activation = true;
        }
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

// MARK: Clipboard

// The largest text or file list accepted from the remote computer: 16 MiB.
#define VISTARA_MAX_CLIPBOARD_BYTES (16u * 1024u * 1024u)

/// Whether this Mac's files can be offered: the connection copies files and
/// the server can ask for their contents.
static bool can_offer_files(const vistara_session *session) {
    return session->copy_files && (session->server_clipboard_flags & CB_STREAM_FILECLIP_ENABLED);
}

static UINT clipboard_send_format_list(vistara_session *session) {
    // Call with clipboard_lock held.
    CLIPRDR_FORMAT formats[2] = {0};
    CLIPRDR_FORMAT_LIST list = {0};
    list.common.msgType = CB_FORMAT_LIST;
    if (session->local_text) {
        formats[0] = (CLIPRDR_FORMAT){.formatId = CF_UNICODETEXT, .formatName = NULL};
        list.numFormats = 1;
    } else if (session->files.offered_count > 0 && can_offer_files(session)) {
        formats[0] = (CLIPRDR_FORMAT){.formatId = VISTARA_FORMAT_FILE_LIST, .formatName = "FileGroupDescriptorW"};
        formats[1] = (CLIPRDR_FORMAT){.formatId = VISTARA_FORMAT_FILE_CONTENTS, .formatName = "FileContents"};
        list.numFormats = 2;
    }
    list.formats = list.numFormats > 0 ? formats : NULL;
    return session->clipboard->ClientFormatList(session->clipboard, &list);
}

static UINT clipboard_monitor_ready(CliprdrClientContext *clipboard, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    vistara_session *session = clipboard->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES | (session->copy_files ? VISTARA_FILE_CAPABILITIES : 0);
    CLIPRDR_CAPABILITIES capabilities = {0};
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;

    pthread_mutex_lock(&session->clipboard_lock);
    UINT result = clipboard->ClientCapabilities(clipboard, &capabilities);
    if (result == CHANNEL_RC_OK) {
        result = clipboard_send_format_list(session);
    }
    session->clipboard_ready = result == CHANNEL_RC_OK;
    pthread_mutex_unlock(&session->clipboard_lock);
    return result;
}

static UINT clipboard_server_capabilities(CliprdrClientContext *clipboard,
                                          const CLIPRDR_CAPABILITIES *capabilities) {
    vistara_session *session = clipboard->custom;
    uint32_t flags = 0;
    const BYTE *set = (const BYTE *)capabilities->capabilitySets;
    for (UINT32 index = 0; set && index < capabilities->cCapabilitiesSets; index++) {
        const CLIPRDR_CAPABILITY_SET *each = (const CLIPRDR_CAPABILITY_SET *)set;
        if (each->capabilitySetType == CB_CAPSTYPE_GENERAL) {
            flags = ((const CLIPRDR_GENERAL_CAPABILITY_SET *)set)->generalFlags;
        }
        if (each->capabilitySetLength == 0) {
            break;
        }
        set += each->capabilitySetLength;
    }
    pthread_mutex_lock(&session->clipboard_lock);
    session->server_clipboard_flags = flags;
    pthread_mutex_unlock(&session->clipboard_lock);
    return CHANNEL_RC_OK;
}

static UINT clipboard_request(CliprdrClientContext *clipboard, uint32_t format) {
    CLIPRDR_FORMAT_DATA_REQUEST request = {0};
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = format;
    return clipboard->ClientFormatDataRequest(clipboard, &request);
}

/// The remote computer copied something: acknowledge, and fetch its file list
/// or text, the list first. File contents wait until they are asked for.
static UINT clipboard_server_format_list(CliprdrClientContext *clipboard, const CLIPRDR_FORMAT_LIST *list) {
    vistara_session *session = clipboard->custom;
    CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT result = clipboard->ClientFormatListResponse(clipboard, &response);
    if (result != CHANNEL_RC_OK) {
        return result;
    }
    bool has_text = false;
    uint32_t file_list = 0;
    bool has_file_list = false;
    for (UINT32 index = 0; index < list->numFormats; index++) {
        const CLIPRDR_FORMAT *format = &list->formats[index];
        if (format->formatId == CF_UNICODETEXT) {
            has_text = true;
        } else if (format->formatName && strcmp(format->formatName, "FileGroupDescriptorW") == 0) {
            file_list = format->formatId;
            has_file_list = true;
        }
    }
    pthread_mutex_lock(&session->clipboard_lock);
    has_file_list = has_file_list && session->copy_files;
    if (session->copy_files) {
        vistara_files_remote_changed(&session->files, has_file_list);
    }
    session->text_after_files = has_file_list && has_text;
    session->awaiting = has_file_list ? VISTARA_AWAITING_FILE_LIST
                        : has_text    ? VISTARA_AWAITING_TEXT
                                      : VISTARA_AWAITING_NOTHING;
    const vistara_awaiting awaiting = session->awaiting;
    pthread_mutex_unlock(&session->clipboard_lock);
    vistara_session_wake(session);
    switch (awaiting) {
    case VISTARA_AWAITING_FILE_LIST:
        return clipboard_request(clipboard, file_list);
    case VISTARA_AWAITING_TEXT:
        return clipboard_request(clipboard, CF_UNICODETEXT);
    default:
        return CHANNEL_RC_OK;
    }
}

static UINT clipboard_server_format_list_response(CliprdrClientContext *clipboard,
                                                  const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)clipboard, (void)response;
    return CHANNEL_RC_OK;
}

/// The remote computer pastes: hand over this Mac's text or file list, or say
/// there is none.
static UINT clipboard_server_format_data_request(CliprdrClientContext *clipboard,
                                                 const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    vistara_session *session = clipboard->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    pthread_mutex_lock(&session->clipboard_lock);
    if (request->requestedFormatId == VISTARA_FORMAT_FILE_LIST && can_offer_files(session) &&
        session->files.offered_count > 0) {
        const UINT result =
            vistara_files_answer_list_request(&session->files, clipboard, session->server_clipboard_flags);
        pthread_mutex_unlock(&session->clipboard_lock);
        return result;
    }
    if (request->requestedFormatId == CF_UNICODETEXT && session->local_text) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)session->local_text_bytes;
        response.requestedFormatData = (const BYTE *)session->local_text;
        session->clipboard_bytes_sent += session->local_text_bytes;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    const UINT result = clipboard->ClientFormatDataResponse(clipboard, &response);
    pthread_mutex_unlock(&session->clipboard_lock);
    return result;
}

static void take_remote_text(vistara_session *session, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    // Call with clipboard_lock held.
    if (!(response->common.msgFlags & CB_RESPONSE_OK) || !response->requestedFormatData ||
        response->common.dataLen < sizeof(WCHAR) || response->common.dataLen > VISTARA_MAX_CLIPBOARD_BYTES) {
        return;
    }
    const WCHAR *text = (const WCHAR *)response->requestedFormatData;
    size_t length = response->common.dataLen / sizeof(WCHAR);
    // The text ends at its first zero, if it has one.
    for (size_t index = 0; index < length; index++) {
        if (text[index] == 0) {
            length = index;
            break;
        }
    }
    char *converted = ConvertWCharNToUtf8Alloc(text, length, NULL);
    if (converted) {
        free(session->remote_text);
        session->remote_text = converted;
    }
}

/// The remote computer's text or file list arrived.
static UINT clipboard_server_format_data_response(CliprdrClientContext *clipboard,
                                                  const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    vistara_session *session = clipboard->custom;
    UINT result = CHANNEL_RC_OK;
    pthread_mutex_lock(&session->clipboard_lock);
    const vistara_awaiting awaiting = session->awaiting;
    session->awaiting = VISTARA_AWAITING_NOTHING;
    if (awaiting == VISTARA_AWAITING_TEXT) {
        take_remote_text(session, response);
    } else if (awaiting == VISTARA_AWAITING_FILE_LIST) {
        const bool usable = (response->common.msgFlags & CB_RESPONSE_OK) && response->requestedFormatData &&
                            response->common.dataLen <= VISTARA_MAX_CLIPBOARD_BYTES;
        vistara_files_take_list(&session->files, usable ? response->requestedFormatData : NULL,
                                usable ? response->common.dataLen : 0);
        if (session->text_after_files) {
            session->text_after_files = false;
            session->awaiting = VISTARA_AWAITING_TEXT;
        }
    }
    const bool ask_for_text = session->awaiting == VISTARA_AWAITING_TEXT;
    pthread_mutex_unlock(&session->clipboard_lock);
    if (ask_for_text) {
        result = clipboard_request(clipboard, CF_UNICODETEXT);
    }
    vistara_session_wake(session);
    return result;
}

/// The remote computer asks for a part of a file this Mac offered.
static UINT clipboard_server_file_contents_request(CliprdrClientContext *clipboard,
                                                   const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    vistara_session *session = clipboard->custom;
    pthread_mutex_lock(&session->clipboard_lock);
    const uint64_t before = session->files.bytes_sent;
    const UINT result = vistara_files_answer_contents_request(&session->files, clipboard, request);
    session->clipboard_bytes_sent += session->files.bytes_sent - before;
    pthread_mutex_unlock(&session->clipboard_lock);
    return result;
}

/// A part of a file being fetched arrived.
static UINT clipboard_server_file_contents_response(CliprdrClientContext *clipboard,
                                                    const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
    vistara_session *session = clipboard->custom;
    pthread_mutex_lock(&session->clipboard_lock);
    vistara_files_contents_response(&session->files, clipboard, response);
    pthread_mutex_unlock(&session->clipboard_lock);
    vistara_session_wake(session);
    return CHANNEL_RC_OK;
}

/// The remote computer keeps what this Mac offers now for the requests that
/// name this lock, until it unlocks it.
static UINT clipboard_server_lock(CliprdrClientContext *clipboard, const CLIPRDR_LOCK_CLIPBOARD_DATA *lock) {
    vistara_session *session = clipboard->custom;
    pthread_mutex_lock(&session->clipboard_lock);
    vistara_files_lock(&session->files, lock->clipDataId);
    pthread_mutex_unlock(&session->clipboard_lock);
    return CHANNEL_RC_OK;
}

static UINT clipboard_server_unlock(CliprdrClientContext *clipboard, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *unlock) {
    vistara_session *session = clipboard->custom;
    pthread_mutex_lock(&session->clipboard_lock);
    vistara_files_unlock(&session->files, unlock->clipDataId);
    pthread_mutex_unlock(&session->clipboard_lock);
    return CHANNEL_RC_OK;
}

static void clipboard_connected(vistara_session *session, CliprdrClientContext *clipboard) {
    clipboard->custom = session;
    clipboard->MonitorReady = clipboard_monitor_ready;
    clipboard->ServerCapabilities = clipboard_server_capabilities;
    clipboard->ServerFormatList = clipboard_server_format_list;
    clipboard->ServerFormatListResponse = clipboard_server_format_list_response;
    clipboard->ServerFormatDataRequest = clipboard_server_format_data_request;
    clipboard->ServerFormatDataResponse = clipboard_server_format_data_response;
    clipboard->ServerFileContentsRequest = clipboard_server_file_contents_request;
    clipboard->ServerFileContentsResponse = clipboard_server_file_contents_response;
    clipboard->ServerLockClipboardData = clipboard_server_lock;
    clipboard->ServerUnlockClipboardData = clipboard_server_unlock;
    pthread_mutex_lock(&session->clipboard_lock);
    session->clipboard = clipboard;
    session->clipboard_ever_connected = true;
    pthread_mutex_unlock(&session->clipboard_lock);
}

static void clipboard_disconnected(vistara_session *session) {
    pthread_mutex_lock(&session->clipboard_lock);
    session->clipboard = NULL;
    session->clipboard_ready = false;
    session->awaiting = VISTARA_AWAITING_NOTHING;
    vistara_files_channel_closed(&session->files);
    pthread_mutex_unlock(&session->clipboard_lock);
}

char *vistara_session_take_remote_text(vistara_session *session) {
    pthread_mutex_lock(&session->clipboard_lock);
    char *text = session->remote_text;
    session->remote_text = NULL;
    pthread_mutex_unlock(&session->clipboard_lock);
    return text;
}

void vistara_session_offer_local_text(vistara_session *session, const char *text) {
    size_t length = 0;
    WCHAR *converted = ConvertUtf8ToWCharAlloc(text, &length);
    if (!converted) {
        return;
    }
    pthread_mutex_lock(&session->clipboard_lock);
    if (!session->share_clipboard) {
        free(converted);
        pthread_mutex_unlock(&session->clipboard_lock);
        return;
    }
    free(session->local_text);
    session->local_text = converted;
    session->local_text_bytes = (length + 1) * sizeof(WCHAR);
    (void)vistara_files_set_offer(&session->files, NULL, 0);
    if (session->clipboard && session->clipboard_ready) {
        (void)clipboard_send_format_list(session);
    }
    pthread_mutex_unlock(&session->clipboard_lock);
}

bool vistara_session_offer_local_files(vistara_session *session, const vistara_local_file *files, size_t count) {
    pthread_mutex_lock(&session->clipboard_lock);
    if (!session->copy_files) {
        pthread_mutex_unlock(&session->clipboard_lock);
        return false;
    }
    free(session->local_text);
    session->local_text = NULL;
    session->local_text_bytes = 0;
    const bool offered = vistara_files_set_offer(&session->files, files, files ? count : 0);
    if (session->clipboard && session->clipboard_ready) {
        (void)clipboard_send_format_list(session);
    }
    pthread_mutex_unlock(&session->clipboard_lock);
    return offered;
}

bool vistara_session_take_remote_files(vistara_session *session, vistara_remote_file **files, size_t *count,
                                       uint64_t *list_id) {
    pthread_mutex_lock(&session->clipboard_lock);
    const bool changed = session->files.has_untaken;
    *files = changed ? session->files.untaken : NULL;
    *count = changed ? session->files.untaken_count : 0;
    *list_id = session->files.list_id;
    if (changed) {
        session->files.untaken = NULL;
        session->files.untaken_count = 0;
        session->files.has_untaken = false;
    }
    pthread_mutex_unlock(&session->clipboard_lock);
    return changed;
}

bool vistara_session_start_fetch(vistara_session *session, uint64_t list_id, const vistara_fetch_item *items,
                                 size_t count) {
    pthread_mutex_lock(&session->clipboard_lock);
    const bool can_lock = (session->server_clipboard_flags & CB_CAN_LOCK_CLIPDATA) != 0;
    const bool started =
        session->clipboard && session->copy_files &&
        vistara_files_start_fetch(&session->files, session->clipboard, list_id, items, count, can_lock);
    pthread_mutex_unlock(&session->clipboard_lock);
    return started;
}

void vistara_session_cancel_fetch(vistara_session *session) {
    pthread_mutex_lock(&session->clipboard_lock);
    vistara_files_end_fetch(&session->files, VISTARA_FETCH_CANCELLED, 0);
    pthread_mutex_unlock(&session->clipboard_lock);
}

void vistara_session_read_fetch(vistara_session *session, vistara_fetch_status *status) {
    pthread_mutex_lock(&session->clipboard_lock);
    *status = session->files.status;
    pthread_mutex_unlock(&session->clipboard_lock);
}

bool vistara_session_clipboard_connected(vistara_session *session) {
    pthread_mutex_lock(&session->clipboard_lock);
    const bool connected = session->clipboard_ever_connected;
    pthread_mutex_unlock(&session->clipboard_lock);
    return connected;
}

uint64_t vistara_session_clipboard_bytes_sent(vistara_session *session) {
    pthread_mutex_lock(&session->clipboard_lock);
    const uint64_t sent = session->clipboard_bytes_sent;
    pthread_mutex_unlock(&session->clipboard_lock);
    return sent;
}

// MARK: Channels

// Vistara loads exactly the channels it uses instead of FreeRDP's general
// loader, which adds several more depending on defaults: display control,
// which is a dynamic channel and needs drdynvc to carry it, and sound and the
// clipboard when the connection uses them.

static pthread_once_t addin_provider_once = PTHREAD_ONCE_INIT;

static BOOL load_static_channel(rdpContext *context, const char *name, void *data) {
    PVIRTUALCHANNELENTRY entry = freerdp_load_channel_addin_entry(
        name, NULL, NULL, FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    if (!entry) {
        return FALSE;
    }
    return freerdp_channels_client_load_ex(context->channels, context->settings,
                                           WINPR_FUNC_PTR_CAST(entry, PVIRTUALCHANNELENTRYEX), data) == 0;
}

/// Finds channels and their parts: the shim's own sound output, shared
/// folders, and printer, and everything else among the channels compiled
/// into libfreerdp-client.
static PVIRTUALCHANNELENTRY load_addin_entry(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags) {
    if (name && subsystem && strcmp(name, "printer") == 0 &&
        strncmp(subsystem, VISTARA_PRINTER_SUBSYSTEM, strlen(VISTARA_PRINTER_SUBSYSTEM)) == 0) {
        return WINPR_FUNC_PTR_CAST(&vistara_printer_backend_entry, PVIRTUALCHANNELENTRY);
    }
    if (name && subsystem && strcmp(name, RDPSND_CHANNEL_NAME) == 0 &&
        strcmp(subsystem, VISTARA_AUDIO_SUBSYSTEM) == 0) {
        return WINPR_FUNC_PTR_CAST(&vistara_rdpsnd_device_entry, PVIRTUALCHANNELENTRY);
    }
    if (name && type && strcmp(name, VISTARA_DRIVE_SERVICE_NAME) == 0 && strcmp(type, "DeviceServiceEntry") == 0) {
        return WINPR_FUNC_PTR_CAST(&vistara_drive_service_entry, PVIRTUALCHANNELENTRY);
    }
    return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}

static void register_addin_provider(void) {
    (void)freerdp_register_addin_provider(load_addin_entry, 0);
}

bool vistara_drive_is_read_only(rdpContext *context, const char *path) {
    if (!context || !path) {
        return false;
    }
    const vistara_session *session = session_of(context);
    for (size_t index = 0; index < session->read_only_count; index++) {
        if (strcmp(session->read_only_paths[index], path) == 0) {
            return true;
        }
    }
    return false;
}

uint64_t vistara_drive_refused_count(void) {
    return atomic_load(&vistara_drive_refused_requests);
}

/// Adds each shared folder as a drive. A folder without a name or an
/// absolute path fails the connection instead of being left out silently.
static bool add_shared_folders(vistara_session *session, rdpSettings *settings,
                               const vistara_connect_options *options) {
    session->shared_folder_count = options->shared_folders ? options->shared_folder_count : 0;
    if (session->shared_folder_count == 0) {
        return true;
    }
    session->read_only_paths = calloc(session->shared_folder_count, sizeof(char *));
    if (!session->read_only_paths) {
        return false;
    }
    for (size_t index = 0; index < session->shared_folder_count; index++) {
        const vistara_shared_folder *folder = &options->shared_folders[index];
        if (!folder->name || !folder->name[0] || !folder->path || folder->path[0] != '/') {
            return false;
        }
        const char *const arguments[] = {folder->name, folder->path};
        RDPDR_DEVICE *device = freerdp_device_new(RDPDR_DTYP_FILESYSTEM, ARRAYSIZE(arguments), arguments);
        if (!device || !freerdp_device_collection_add(settings, device)) {
            freerdp_device_free(device);
            return false;
        }
        if (folder->read_only) {
            char *path = strdup(folder->path);
            if (!path) {
                return false;
            }
            session->read_only_paths[session->read_only_count++] = path;
        }
    }
    return true;
}

static void wake_for_printed(void *session) {
    vistara_session_wake(session);
}

/// Adds the printer "Vistara", whose documents go to the spool in
/// `options->print_folder`. FreeRDP keeps what the remote computer tells it
/// about its printers in FreeRDP_ConfigPath, which is put in that folder too.
static bool add_printer(vistara_session *session, rdpSettings *settings, const vistara_connect_options *options) {
    if (!options->print_folder) {
        return true;
    }
    session->print_spool = vistara_print_spool_new(options->print_folder, VISTARA_PRINT_LIMIT);
    if (!session->print_spool) {
        return false;
    }
    vistara_print_spool_set_notify(session->print_spool, wake_for_printed, session);
    session->printer_id = vistara_printer_register(session->print_spool);
    char driver[96];
    char config[1024];
    if (session->printer_id == 0 ||
        snprintf(driver, sizeof(driver), "%s:%s-%u", VISTARA_PRINTER_DRIVER, VISTARA_PRINTER_SUBSYSTEM,
                 (unsigned)session->printer_id) >= (int)sizeof(driver) ||
        snprintf(config, sizeof(config), "%s/.freerdp", options->print_folder) >= (int)sizeof(config)) {
        return false;
    }
    const char *const arguments[] = {VISTARA_PRINTER_NAME, driver};
    RDPDR_DEVICE *device = freerdp_device_new(RDPDR_DTYP_PRINT, ARRAYSIZE(arguments), arguments);
    if (!device || !freerdp_device_collection_add(settings, device)) {
        freerdp_device_free(device);
        return false;
    }
    return freerdp_settings_set_string(settings, FreeRDP_ConfigPath, config) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, TRUE);
}

/// Whether the device redirection channel is loaded: for shared folders or the printer.
static bool uses_device_redirection(const vistara_session *session) {
    return session->shared_folder_count > 0 || session->print_spool != NULL;
}

bool vistara_session_take_printed(vistara_session *session, vistara_printed_document **documents, size_t *count) {
    if (!session->print_spool) {
        *documents = NULL;
        *count = 0;
        return false;
    }
    return vistara_print_spool_take(session->print_spool, documents, count);
}

vistara_audio_stats *vistara_audio_stats_for(rdpContext *context) {
    return context ? &session_of(context)->audio : NULL;
}

void vistara_session_read_audio(vistara_session *session, vistara_audio_status *status) {
    const vistara_audio_stats *audio = &session->audio;
    status->frames_received = atomic_load(&audio->frames_received);
    status->frames_dropped = atomic_load(&audio->frames_dropped);
    status->sample_rate = (uint32_t)atomic_load(&audio->sample_rate);
    status->channels = (uint32_t)atomic_load(&audio->channels);
    status->outputs_opened = (uint32_t)atomic_load(&audio->outputs_opened);
    status->output_changes = (uint32_t)atomic_load(&audio->output_changes);
    status->output_running = atomic_load(&audio->output_running);
    status->channel_loaded = session->audio_args != NULL;
}

/// Loads the sound channel with the shim's output, which plays on this Mac.
static BOOL load_audio_channel(rdpContext *context) {
    vistara_session *session = session_of(context);
    const char *const arguments[] = {RDPSND_CHANNEL_NAME, "sys:" VISTARA_AUDIO_SUBSYSTEM};
    session->audio_args = freerdp_addin_argv_new(ARRAYSIZE(arguments), arguments);
    return session->audio_args && load_static_channel(context, RDPSND_CHANNEL_NAME, session->audio_args);
}

static BOOL load_channels(freerdp *instance) {
    rdpContext *context = instance->context;
    // Sound only when it plays here: otherwise none is sent to this Mac.
    if (session_of(context)->play_audio_here && !load_audio_channel(context)) {
        return FALSE;
    }
    // Device redirection only for shared folders and the printer, and with only them.
    if (uses_device_redirection(session_of(context)) &&
        !load_static_channel(context, RDPDR_SVC_CHANNEL_NAME, context->settings)) {
        return FALSE;
    }
    // The clipboard only when shared: unloaded, no clipboard data can pass.
    if (session_of(context)->share_clipboard && !load_static_channel(context, CLIPRDR_SVC_CHANNEL_NAME, NULL)) {
        return FALSE;
    }
    const char *const display_control[] = {DISP_CHANNEL_NAME};
    if (!freerdp_client_add_dynamic_channel(context->settings, 1, display_control) ||
        !freerdp_settings_set_bool(context->settings, FreeRDP_SupportDynamicChannels, TRUE)) {
        return FALSE;
    }
    return load_static_channel(context, DRDYNVC_SVC_CHANNEL_NAME, context->settings);
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
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 && event->pInterface) {
        clipboard_connected(session, event->pInterface);
        return;
    }
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0 && event->pInterface) {
        DispClientContext *display_control = event->pInterface;
        display_control->custom = session;
        display_control->DisplayControlCaps = display_control_caps;
        atomic_store(&session->display_control, display_control);
    }
}

/// The server started an activation, the connection's first or a new one
/// (after a Deactivate All): a waiting Suppress Output waits for its end.
static void activation_began(void *context, const ActivatedEventArgs *event) {
    (void)event;
    vistara_session *session = session_of(context);
    session->activation_started = GetTickCount64();
    session->painted_since_activation = false;
}

static void channel_disconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    vistara_session *session = session_of(context);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        clipboard_disconnected(session);
        return;
    }
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
    DISPLAY_CONTROL_MONITOR_LAYOUT layout[VISTARA_MAX_MONITORS];
    const size_t count = vistara_display_layout(session->pending_monitors, session->pending_monitor_count, layout);
    (void)display_control->SendMonitorLayout(display_control, (UINT32)count, layout);
}

bool vistara_session_request_size(vistara_session *session, uint32_t width, uint32_t height,
                                  uint32_t scale_percent) {
    const vistara_monitor monitor = {
        .x = 0, .y = 0, .width = width, .height = height, .is_primary = true, .scale_percent = scale_percent,
    };
    return vistara_session_request_layout(session, &monitor, 1);
}

bool vistara_session_request_layout(vistara_session *session, const vistara_monitor *monitors, size_t count) {
    if (!session->connected || count == 0) {
        return false;
    }
    if (count > VISTARA_MAX_MONITORS) count = VISTARA_MAX_MONITORS;
    memcpy(session->pending_monitors, monitors, count * sizeof(*monitors));
    session->pending_monitor_count = count;
    session->has_pending_size = true;
    send_pending_size(session);
    return true;
}

static bool supports_display_updates(rdpContext *context) {
    // The server's General Capability Set said whether it supports this.
    return freerdp_settings_get_bool(context->settings, FreeRDP_SuppressOutput) && context->update->SuppressOutput;
}

/// How long a waiting Suppress Output waits for the server's first picture.
static const uint64_t display_updates_picture_wait_ms = 1000;

/// Sends a waiting Suppress Output once the connection is active and the
/// server is done activating it. Sent while the server is (re)activating the
/// connection, it can make the server drop it.
///
/// Active alone is not enough: a server may resize the desktop the moment the
/// client turns active, which starts an activation the client learns of only
/// later. The server's first picture after an activation says it is done. A
/// server told to send no pictures may send none, and one may be slow, so after
/// a second the update goes anyway.
static void send_pending_display_updates(vistara_session *session) {
    rdpContext *context = session->instance->context;
    if (!session->has_pending_display_updates || !session->connected ||
        freerdp_get_state(context) != CONNECTION_STATE_ACTIVE) {
        return;
    }
    const bool settled = session->painted_since_activation || !session->server_sends_pictures ||
                         GetTickCount64() - session->activation_started >= display_updates_picture_wait_ms;
    if (!settled) {
        return;
    }
    session->has_pending_display_updates = false;
    const bool allowed = session->pending_display_updates_allowed;
    session->server_sends_pictures = allowed;
    const uint32_t width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const uint32_t height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    const RECTANGLE_16 desktop = {
        .left = 0,
        .top = 0,
        .right = (UINT16)(width > UINT16_MAX ? UINT16_MAX : width),
        .bottom = (UINT16)(height > UINT16_MAX ? UINT16_MAX : height),
    };
    (void)context->update->SuppressOutput(context, allowed ? 1 : 0, allowed ? &desktop : NULL);
}

bool vistara_session_set_display_updates(vistara_session *session, bool allowed) {
    if (!session->connected || !supports_display_updates(session->instance->context)) {
        return false;
    }
    session->has_pending_display_updates = true;
    session->pending_display_updates_allowed = allowed;
    send_pending_display_updates(session);
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

    pthread_mutex_init(&session->clipboard_lock, NULL);
    vistara_files_init(&session->files);
    session->server_sends_pictures = true;
    session->wake_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!session->wake_event) {
        pthread_mutex_destroy(&session->clipboard_lock);
        free(session);
        return NULL;
    }
    session->instance = freerdp_new();
    if (!session->instance) {
        (void)CloseHandle(session->wake_event);
        pthread_mutex_destroy(&session->clipboard_lock);
        free(session);
        return NULL;
    }

    freerdp *instance = session->instance;
    instance->ContextSize = sizeof(vistara_context);
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->VerifyX509Certificate = verify_x509_certificate;
    instance->PresentGatewayMessage = present_gateway_message;
    instance->LoadChannels = load_channels;
    (void)pthread_once(&addin_provider_once, register_addin_provider);

    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        (void)CloseHandle(session->wake_event);
        pthread_mutex_destroy(&session->clipboard_lock);
        free(session);
        return NULL;
    }
    ((vistara_context *)instance->context)->session = session;
    if (!wrap_tcp_connect(session) ||
        PubSub_SubscribeChannelConnected(instance->context->pubSub, channel_connected) < 0 ||
        PubSub_SubscribeChannelDisconnected(instance->context->pubSub, channel_disconnected) < 0 ||
        PubSub_SubscribeActivated(instance->context->pubSub, activation_began) < 0) {
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
    vistara_printer_unregister(session->printer_id);
    freerdp_context_free(session->instance);
    freerdp_free(session->instance);
    // After the channels: a document still arriving is removed with the spool.
    vistara_print_spool_free(session->print_spool);
    (void)CloseHandle(session->wake_event);
    free(session->cursor_pixels);
    free(session->local_text);
    free(session->remote_text);
    vistara_files_free(&session->files);
    freerdp_addin_argv_free(session->audio_args);
    for (size_t index = 0; index < session->read_only_count; index++) {
        free(session->read_only_paths[index]);
    }
    free(session->read_only_paths);
    pthread_mutex_destroy(&session->clipboard_lock);
    free(session);
}

/// TLS1_2_VERSION from OpenSSL's prov_ssl.h, which the shim does not include.
#define VISTARA_TLS1_2_VERSION 0x0303

void vistara_session_read_settings(const vistara_session *session, vistara_security_settings *out) {
    const rdpSettings *settings = session->instance->context->settings;
    out->nla = freerdp_settings_get_bool(settings, FreeRDP_NlaSecurity);
    out->tls = freerdp_settings_get_bool(settings, FreeRDP_TlsSecurity);
    out->rdp = freerdp_settings_get_bool(settings, FreeRDP_RdpSecurity);
    out->tls_min_version = freerdp_settings_get_uint16(settings, FreeRDP_TLSMinVersion);
    out->tls_security_level = freerdp_settings_get_uint32(settings, FreeRDP_TlsSecLevel);
    out->remote_console_audio = freerdp_settings_get_bool(settings, FreeRDP_RemoteConsoleAudio);
    out->audio_playback = freerdp_settings_get_bool(settings, FreeRDP_AudioPlayback);
    out->desktop_scale_factor = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);
    out->keyboard_layout = freerdp_settings_get_uint32(settings, FreeRDP_KeyboardLayout);
    out->keyboard_type = freerdp_settings_get_uint32(settings, FreeRDP_KeyboardType);
    out->gateway_enabled = freerdp_settings_get_bool(settings, FreeRDP_GatewayEnabled);
    out->gateway_usage_method = freerdp_settings_get_uint32(settings, FreeRDP_GatewayUsageMethod);
    out->gateway_bypass_local = freerdp_settings_get_bool(settings, FreeRDP_GatewayBypassLocal);
    out->gateway_http_transport = freerdp_settings_get_bool(settings, FreeRDP_GatewayHttpTransport);
    out->gateway_websockets = freerdp_settings_get_bool(settings, FreeRDP_GatewayHttpUseWebsockets);
    out->gateway_rpc_transport = freerdp_settings_get_bool(settings, FreeRDP_GatewayRpcTransport);
    out->gateway_udp_transport = freerdp_settings_get_bool(settings, FreeRDP_GatewayUdpTransport);
    out->gateway_same_credentials = freerdp_settings_get_bool(settings, FreeRDP_GatewayUseSameCredentials);
    out->gateway_port = freerdp_settings_get_uint32(settings, FreeRDP_GatewayPort);
    out->device_redirection = freerdp_settings_get_bool(settings, FreeRDP_DeviceRedirection);
}

static uint32_t clipboard_features(const vistara_connect_options *options) {
    const uint32_t text = CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL;
    const uint32_t files = CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES | CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES;
    return options->share_clipboard && options->copy_files ? text | files : text;
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
           // TLS 1.2 or newer with OpenSSL's 112-bit security level. These are
           // FreeRDP 3.33's defaults too; set here so an update cannot lower
           // them unnoticed. No option weakens them.
           freerdp_settings_set_uint16(settings, FreeRDP_TLSMinVersion, VISTARA_TLS1_2_VERSION) &&
           freerdp_settings_set_uint32(settings, FreeRDP_TlsSecLevel, FREERDP_TLS_SECLEVEL_112BIT) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, options->play_audio_on_remote) &&
           // Without it the server is told not to send sound at all.
           freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, options->play_audio_here) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, options->share_clipboard) &&
           // Never the home folder or all drives: only the folders given.
           freerdp_settings_set_bool(settings, FreeRDP_RedirectHomeDrive, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, FALSE) &&
           // Text both ways, and files only when copied: the clipboard
           // channel itself drops every file message otherwise.
           freerdp_settings_set_uint32(settings, FreeRDP_ClipboardFeatureMask, clipboard_features(options)) &&
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

/// The keyboard announced in the client core data, which FreeRDP writes from
/// these settings. Nothing is changed for a layout of 0.
static bool apply_keyboard(rdpSettings *settings, const vistara_connect_options *options) {
    if (options->keyboard_layout == 0) {
        return true;
    }
    if (!freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, options->keyboard_layout)) {
        return false;
    }
    if (options->keyboard_type == 0) {
        return true;
    }
    return freerdp_settings_set_uint32(settings, FreeRDP_KeyboardType, options->keyboard_type) &&
           freerdp_settings_set_uint32(settings, FreeRDP_KeyboardSubType, options->keyboard_subtype) &&
           freerdp_settings_set_uint32(settings, FreeRDP_KeyboardFunctionKey, options->keyboard_function_keys);
}

vistara_connect_result vistara_session_connect(vistara_session *session,
                                               const vistara_connect_options *options) {
    if (session->connect_attempted) {
        return VISTARA_CONNECT_FAILED;
    }
    session->connect_attempted = true;
    session->tcp_os_error = 0;

    pthread_mutex_lock(&session->clipboard_lock);
    session->share_clipboard = options->share_clipboard;
    session->copy_files = options->share_clipboard && options->copy_files;
    pthread_mutex_unlock(&session->clipboard_lock);
    session->play_audio_here = options->play_audio_here && !options->play_audio_on_remote;
    session->decide_certificate = options->decide_certificate;
    session->decide_certificate_context = options->decide_certificate_context;
    session->decide_gateway_message = options->decide_gateway_message;
    session->decide_gateway_message_context = options->decide_gateway_message_context;
    session->uses_gateway = options->gateway_host != NULL;
    if (!apply_options(session->instance->context->settings, options) ||
        !apply_gateway(session->instance->context->settings, options) ||
        !apply_keyboard(session->instance->context->settings, options) ||
        !vistara_apply_monitors(session->instance->context->settings, options->monitors, options->monitor_count) ||
        !add_shared_folders(session, session->instance->context->settings, options) ||
        !add_printer(session, session->instance->context->settings, options) ||
        !freerdp_settings_set_bool(session->instance->context->settings, FreeRDP_DeviceRedirection,
                                   uses_device_redirection(session))) {
        return VISTARA_CONNECT_FAILED;
    }

    if (freerdp_connect(session->instance)) {
        session->connected = true;
        return VISTARA_CONNECT_OK;
    }

    if (session->certificate_rejected) {
        return VISTARA_CONNECT_CERTIFICATE_UNTRUSTED;
    }
    // A refused gateway sign-in is not the computer's: it is told apart from
    // the error code by vistara_session_failed_at_gateway().
    if (vistara_session_failed_at_gateway(session) &&
        freerdp_get_last_error(session->instance->context) != FREERDP_ERROR_CONNECT_CANCELLED) {
        return VISTARA_CONNECT_FAILED;
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
    send_pending_display_updates(session);
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
