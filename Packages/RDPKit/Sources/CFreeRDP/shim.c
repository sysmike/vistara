#include "CFreeRDP.h"
#include "audio.h"
#include "drive.h"
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
    // The clipboard channel. Its handlers may run on another thread than the
    // session's, so everything below is guarded by clipboard_lock.
    pthread_mutex_t clipboard_lock;
    CliprdrClientContext *clipboard;
    bool share_clipboard;
    bool clipboard_ready;
    bool clipboard_ever_connected;
    bool awaiting_remote_text;
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

// MARK: Clipboard

// The largest text accepted from the remote computer: 16 MiB of UTF-16.
#define VISTARA_MAX_CLIPBOARD_BYTES (16u * 1024u * 1024u)

static UINT clipboard_send_format_list(vistara_session *session) {
    // Call with clipboard_lock held.
    CLIPRDR_FORMAT text = {.formatId = CF_UNICODETEXT, .formatName = NULL};
    CLIPRDR_FORMAT_LIST list = {0};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = session->local_text ? 1 : 0;
    list.formats = session->local_text ? &text : NULL;
    return session->clipboard->ClientFormatList(session->clipboard, &list);
}

static UINT clipboard_monitor_ready(CliprdrClientContext *clipboard, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    vistara_session *session = clipboard->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
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
    (void)clipboard, (void)capabilities;
    return CHANNEL_RC_OK;
}

/// The remote computer copied something: acknowledge, and fetch it if it is text.
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
    for (UINT32 index = 0; index < list->numFormats; index++) {
        if (list->formats[index].formatId == CF_UNICODETEXT) {
            has_text = true;
        }
    }
    if (!has_text) {
        return CHANNEL_RC_OK;
    }
    pthread_mutex_lock(&session->clipboard_lock);
    session->awaiting_remote_text = true;
    pthread_mutex_unlock(&session->clipboard_lock);
    CLIPRDR_FORMAT_DATA_REQUEST request = {0};
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = CF_UNICODETEXT;
    return clipboard->ClientFormatDataRequest(clipboard, &request);
}

static UINT clipboard_server_format_list_response(CliprdrClientContext *clipboard,
                                                  const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)clipboard, (void)response;
    return CHANNEL_RC_OK;
}

/// The remote computer pastes: hand over this Mac's text, or say there is none.
static UINT clipboard_server_format_data_request(CliprdrClientContext *clipboard,
                                                 const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    vistara_session *session = clipboard->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    pthread_mutex_lock(&session->clipboard_lock);
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

/// The remote computer's text arrived.
static UINT clipboard_server_format_data_response(CliprdrClientContext *clipboard,
                                                  const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    vistara_session *session = clipboard->custom;
    pthread_mutex_lock(&session->clipboard_lock);
    const bool expected = session->awaiting_remote_text;
    session->awaiting_remote_text = false;
    if (expected && (response->common.msgFlags & CB_RESPONSE_OK) && response->requestedFormatData &&
        response->common.dataLen >= sizeof(WCHAR) && response->common.dataLen <= VISTARA_MAX_CLIPBOARD_BYTES) {
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
    pthread_mutex_unlock(&session->clipboard_lock);
    vistara_session_wake(session);
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
    pthread_mutex_lock(&session->clipboard_lock);
    session->clipboard = clipboard;
    session->clipboard_ever_connected = true;
    pthread_mutex_unlock(&session->clipboard_lock);
}

static void clipboard_disconnected(vistara_session *session) {
    pthread_mutex_lock(&session->clipboard_lock);
    session->clipboard = NULL;
    session->clipboard_ready = false;
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
    if (session->clipboard && session->clipboard_ready) {
        (void)clipboard_send_format_list(session);
    }
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

/// Finds channels and their parts: the shim's own sound output, and
/// everything else among the channels compiled into libfreerdp-client.
static PVIRTUALCHANNELENTRY load_addin_entry(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags) {
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
        return freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, FALSE);
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
    return freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, TRUE);
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
    // Device redirection only for shared folders, and with only them.
    if (session_of(context)->shared_folder_count > 0 &&
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

bool vistara_session_set_display_updates(vistara_session *session, bool allowed) {
    if (!session->connected) {
        return false;
    }
    rdpContext *context = session->instance->context;
    rdpSettings *settings = context->settings;
    // The server's General Capability Set said whether it supports this.
    if (!freerdp_settings_get_bool(settings, FreeRDP_SuppressOutput) || !context->update->SuppressOutput) {
        return false;
    }
    const uint32_t width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    const uint32_t height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    const RECTANGLE_16 desktop = {
        .left = 0,
        .top = 0,
        .right = (UINT16)(width > UINT16_MAX ? UINT16_MAX : width),
        .bottom = (UINT16)(height > UINT16_MAX ? UINT16_MAX : height),
    };
    return context->update->SuppressOutput(context, allowed ? 1 : 0, allowed ? &desktop : NULL);
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
    free(session->local_text);
    free(session->remote_text);
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
           // Text only, both ways: never files.
           freerdp_settings_set_uint32(settings, FreeRDP_ClipboardFeatureMask,
                                       CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL) &&
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
    pthread_mutex_unlock(&session->clipboard_lock);
    session->play_audio_here = options->play_audio_here && !options->play_audio_on_remote;
    session->decide_certificate = options->decide_certificate;
    session->decide_certificate_context = options->decide_certificate_context;
    if (!apply_options(session->instance->context->settings, options) ||
        !apply_keyboard(session->instance->context->settings, options) ||
        !add_shared_folders(session, session->instance->context->settings, options)) {
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
