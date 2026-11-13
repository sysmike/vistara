#ifndef CFREERDP_H
#define CFREERDP_H

// Narrow C interface between RDPKit and FreeRDP.
//
// This header deliberately includes no FreeRDP or WinPR headers: Swift sees
// only the functions and opaque types declared here. Every FreeRDP call in
// the implementation is checked against the headers of the pinned version.
//
// A session is not thread-safe. Call all functions for one session from the
// same thread, except vistara_session_abort() and vistara_session_wake().

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

/// Receives one line of FreeRDP's log: its level (0 trace to 5 fatal), the
/// function that logged it, and the text. Called on any thread.
typedef void (*vistara_log_sink)(uint32_t level, const char *function, const char *text);

/// Sends all of FreeRDP's and WinPR's log messages to `sink` instead of the
/// console, and sets the level below which messages are dropped (0 trace to
/// 6 off). Binary data, images, and packets are never passed on. Call once,
/// before the first session.
void vistara_logging_install(vistara_log_sink sink, uint32_t level);

/// Changes the level set by vistara_logging_install().
void vistara_logging_set_level(uint32_t level);

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

/// The certificate a server presented. FreeRDP verifies nothing itself and
/// keeps no certificate store of its own: every certificate comes here.
typedef struct {
    const char *host;
    uint16_t port;
    /// The server's certificate followed by the rest of the chain it sent,
    /// as PEM text of `pem_length` bytes. Valid during the callback only.
    const char *pem;
    size_t pem_length;
} vistara_certificate;

/// Decides whether to continue with a certificate. Called on the thread that
/// runs vistara_session_connect(), which blocks until this returns.
typedef bool (*vistara_certificate_decider)(void *_Nullable context,
                                            const vistara_certificate *certificate);

/// A Mac folder shared with the remote computer as a drive.
typedef struct {
    /// The drive's name on the remote computer.
    const char *name;
    /// The folder's absolute path.
    const char *path;
    /// Refuse every request that would change something in the folder.
    bool read_only;
} vistara_shared_folder;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;
    const char *_Nullable domain;
    const char *password;
    uint32_t width;
    uint32_t height;
    /// Desktop scale in percent, 100 to 500.
    uint32_t scale_percent;
    /// When false, the server may negotiate TLS without Network Level
    /// Authentication. Legacy RDP security is never offered.
    bool require_nla;
    /// Ask the server to play sound on the remote computer instead of sending it.
    bool play_audio_on_remote;
    /// Load the sound channel and play the remote computer's sound through
    /// this Mac's default output. Ignored with play_audio_on_remote. With
    /// neither, the server is told not to play sound at all.
    bool play_audio_here;
    /// Load the clipboard channel and share text both ways. When false the
    /// channel is not loaded, so no clipboard data can pass in either direction.
    bool share_clipboard;
    /// The folders to share, each as one drive. With none, the device
    /// redirection channel is not loaded, so nothing on this Mac is shared.
    /// Nothing else is ever shared: not the home folder, not other drives,
    /// and not drives plugged in later.
    const vistara_shared_folder *_Nullable shared_folders;
    size_t shared_folder_count;
    /// The keyboard to announce: a Windows keyboard layout identifier, or 0
    /// to leave the layout to the server. A type of 0 keeps FreeRDP's IBM
    /// enhanced keyboard; otherwise type, subtype, and function keys are sent.
    uint32_t keyboard_layout;
    uint32_t keyboard_type;
    uint32_t keyboard_subtype;
    uint32_t keyboard_function_keys;
    /// Asked about every server certificate. With NULL, every certificate is
    /// rejected: nothing is ever accepted silently.
    vistara_certificate_decider _Nullable decide_certificate;
    void *_Nullable decide_certificate_context;
} vistara_connect_options;

typedef enum {
    VISTARA_CONNECT_OK = 0,
    /// The server's certificate was rejected by the decider, or there was none.
    VISTARA_CONNECT_CERTIFICATE_UNTRUSTED = 1,
    VISTARA_CONNECT_AUTHENTICATION_FAILED = 2,
    /// vistara_session_abort() was called.
    VISTARA_CONNECT_CANCELLED = 3,
    /// Anything else; see vistara_session_last_error_name().
    VISTARA_CONNECT_FAILED = 4,
} vistara_connect_result;

/// Connects with Network Level Authentication and blocks until the
/// connection is established or has failed. A session connects at most once.
vistara_connect_result vistara_session_connect(vistara_session *session,
                                               const vistara_connect_options *options);

/// Makes a running vistara_session_connect() fail and a later
/// vistara_session_poll() return false, as soon as FreeRDP notices. This is
/// the one function that may be called from another thread while the session
/// is in use: it only signals an event. The caller must make sure the session
/// is not destroyed concurrently.
void vistara_session_abort(vistara_session *session);

/// Text the remote computer copied since the last call, as UTF-8 with the
/// remote's line endings, or NULL. The caller frees it with free().
char *_Nullable vistara_session_take_remote_text(vistara_session *session);

/// Offers text (UTF-8) to the remote computer as this Mac's clipboard. The
/// remote computer asks for it when someone pastes there. Does nothing
/// without the clipboard channel.
void vistara_session_offer_local_text(vistara_session *session, const char *text);

/// Whether the clipboard channel came up, and how many bytes of clipboard
/// data were sent to the remote computer. For tests.
bool vistara_session_clipboard_connected(vistara_session *session);
uint64_t vistara_session_clipboard_bytes_sent(vistara_session *session);

/// What the sound channel did, for tests and diagnostics.
typedef struct {
    /// Whether the sound channel was loaded, which it is only for play_audio_here.
    bool channel_loaded;
    /// Audio frames the server sent, and how many of them were not played
    /// because the output was missing or behind.
    uint64_t frames_received;
    uint64_t frames_dropped;
    /// The format the server and this Mac agreed on, once sound has started.
    uint32_t sample_rate;
    uint32_t channels;
    /// How often an output was made: once, and again for each change of the
    /// default output. Zero on a Mac where none can be made.
    uint32_t outputs_opened;
    /// How often the default output changed while sound was playing.
    uint32_t output_changes;
    /// Whether the output is playing. A Mac without any output never does.
    bool output_running;
} vistara_audio_status;

/// Reads what the sound channel did.
void vistara_session_read_audio(vistara_session *session, vistara_audio_status *status);

/// Requests the remote computer made to change a read-only shared folder,
/// which were refused, in all sessions. For tests.
uint64_t vistara_drive_refused_count(void);

/// Makes every session's sound output act as if the user had picked another
/// default output, within half a second. For tests: CI machines have no
/// outputs to switch between.
void vistara_audio_pretend_output_changed(void);

/// The settings a connection attempt handed to FreeRDP, read back from it.
/// For tests: the mapping from Vistara's options is checked against
/// FreeRDP's own values.
typedef struct {
    bool nla;
    bool tls;
    bool rdp;
    uint16_t tls_min_version;
    uint32_t tls_security_level;
    bool remote_console_audio;
    bool audio_playback;
    uint32_t desktop_scale_factor;
    uint32_t keyboard_layout;
    uint32_t keyboard_type;
} vistara_security_settings;

void vistara_session_read_settings(const vistara_session *session, vistara_security_settings *settings);

/// FreeRDP's name for the last error, for example
/// "FREERDP_ERROR_AUTHENTICATION_FAILED". Static storage.
const char *vistara_session_last_error_name(const vistara_session *session);

/// FreeRDP's code for the last error: the class in the upper 16 bits (1 for
/// errors the server reported, 2 for connection errors), the error below.
uint32_t vistara_session_last_error_code(const vistara_session *session);

/// Why the last TCP connection attempt failed, as an errno value
/// (ECONNREFUSED, ETIMEDOUT, EHOSTUNREACH, ...), or 0 when unknown. FreeRDP
/// reports a refused and an unanswered connection alike; this tells them
/// apart. Learning it may cost one short extra connection attempt.
int32_t vistara_session_last_os_error(const vistara_session *session);

/// Tries one TCP connection and returns how it failed, as above. For tests.
int32_t vistara_probe_connection(const char *hostname, uint16_t port, int32_t timeout_ms);

/// FreeRDP's name and English description for an error code. Static storage.
const char *vistara_error_name(uint32_t code);
const char *vistara_error_description(uint32_t code);

/// Waits up to timeout_ms for network activity and processes it. Returns
/// false once the session is disconnected.
bool vistara_session_poll(vistara_session *session, uint32_t timeout_ms);

/// Makes a running vistara_session_poll() return early, for example because
/// input is waiting to be sent. Like vistara_session_abort(), this only
/// signals an event and may be called from another thread, as long as the
/// session is not destroyed concurrently.
void vistara_session_wake(vistara_session *session);

/// Sends a key press or release as an RDP scancode. `extended` selects the
/// extended (E0) variant of the code, as for the arrow keys. Returns false
/// when not connected or when sending failed.
bool vistara_session_send_key(vistara_session *session, uint8_t code, bool extended, bool down);

/// Tells the server the state of the lock keys. The server also treats all
/// keys as released, so this is sent when the keyboard focus returns.
bool vistara_session_send_lock_state(vistara_session *session, bool caps_lock, bool num_lock,
                                     bool scroll_lock);

/// Asks the server to change the desktop to `width` x `height` pixels, shown
/// at `scale_percent` (100 for standard displays, 200 for Retina). The server
/// answers by resizing the framebuffer, which vistara_session_take_dirty()
/// then reports as changed.
///
/// Display control becomes available shortly after connecting. A request made
/// before that is kept and sent by vistara_session_poll() once it can be;
/// a newer request replaces one that is still waiting. A server without
/// display control never answers, and the desktop keeps its size. Returns
/// false only when not connected.
bool vistara_session_request_size(vistara_session *session, uint32_t width, uint32_t height,
                                  uint32_t scale_percent);

/// Whether the server sends the screen ([MS-RDPBCGR] 2.2.11.3, Suppress
/// Output). False while nobody can see the session; true asks for the whole
/// desktop again. Returns false, sending nothing, when the server did not say
/// it supports this, or the session is not connected.
bool vistara_session_set_display_updates(vistara_session *session, bool allowed);

/// Moves the pointer to a position in framebuffer pixels.
bool vistara_session_send_pointer_move(vistara_session *session, uint16_t x, uint16_t y);

/// Presses or releases a mouse button at a position. `button` is 0 for left,
/// 1 for right, 2 for middle, 3 for back, and 4 for forward. Back and forward
/// are ignored by servers that do not support them.
bool vistara_session_send_pointer_button(vistara_session *session, uint8_t button, bool down,
                                         uint16_t x, uint16_t y);

/// Turns the wheel at a position. `rotation` is in wheel units, 120 for one
/// notch, positive for up or right, and is limited to -255...255. Horizontal
/// turns are ignored by servers that do not support them.
bool vistara_session_send_wheel(vistara_session *session, bool horizontal, int16_t rotation,
                                uint16_t x, uint16_t y);

typedef enum {
    /// The system's standard arrow.
    VISTARA_CURSOR_DEFAULT = 0,
    VISTARA_CURSOR_HIDDEN = 1,
    VISTARA_CURSOR_IMAGE = 2,
} vistara_cursor_kind;

/// The cursor the server wants shown.
typedef struct {
    vistara_cursor_kind kind;
    /// For VISTARA_CURSOR_IMAGE: size, hot spot, and `width * height` pixels
    /// of 32-bit BGRA with straight alpha, top row first. The pixels stay
    /// valid until the next vistara_session_poll() or the session's end.
    uint32_t width;
    uint32_t height;
    uint32_t hotspot_x;
    uint32_t hotspot_y;
    const uint8_t *_Nullable pixels;
} vistara_cursor;

/// Reports the cursor if it changed since the last call. Returns false when
/// it did not.
bool vistara_session_take_cursor(vistara_session *session, vistara_cursor *cursor);

/// Framebuffer geometry and pixels (32-bit BGRA, rows of `stride` bytes).
/// Valid while connected; the buffer may move when the desktop is resized.
uint32_t vistara_session_width(const vistara_session *session);
uint32_t vistara_session_height(const vistara_session *session);
uint32_t vistara_session_stride(const vistara_session *session);
const uint8_t *_Nullable vistara_session_framebuffer(const vistara_session *session);

/// A rectangle in framebuffer pixels, origin at the top left.
typedef struct {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
} vistara_rect;

/// Reports the area that changed since the last call, as one rectangle that
/// lies inside the framebuffer, and resets it. Returns false when nothing
/// changed. A desktop resize marks the whole framebuffer.
bool vistara_session_take_dirty(vistara_session *session, vistara_rect *rect);

/// Number of paint cycles that changed the framebuffer since connecting.
uint64_t vistara_session_paint_count(const vistara_session *session);

/// Disconnects. Does nothing if not connected.
void vistara_session_disconnect(vistara_session *session);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#endif
