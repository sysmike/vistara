#ifndef VISTARA_REMOTE_APP_H
#define VISTARA_REMOTE_APP_H

// A RemoteApp session's programs and their windows (docs/DESIGN.md,
// RemoteApp): the RAIL channel, the window orders, and what the session
// tells the remote computer about them.

#include "CFreeRDP.h"

#include <freerdp/client/rail.h>
#include <freerdp/freerdp.h>

/// Points window orders to `app`, which must outlive the connection. Call
/// from post_connect.
void vistara_remote_app_register(rdpContext *context);

/// The RAIL channel came up or went away. `wake` ends the session thread's
/// poll, so what arrives on the channel's thread is seen at once.
void vistara_remote_app_channel_connected(vistara_remote_app *app, RailClientContext *rail,
                                          void (*wake)(void *), void *wake_context);
void vistara_remote_app_channel_disconnected(vistara_remote_app *app);

/// What the session's vistara_session_* functions of the same names do.
bool vistara_remote_app_take_events(vistara_remote_app *app, vistara_remote_app_event **events, size_t *count);
bool vistara_remote_app_start_program(vistara_remote_app *app, const char *program, const char *arguments);
bool vistara_remote_app_activate(vistara_remote_app *app, uint32_t window_id, bool active);
bool vistara_remote_app_move(vistara_remote_app *app, uint32_t window_id, vistara_rect frame);
bool vistara_remote_app_command(vistara_remote_app *app, uint32_t window_id, uint16_t command);
bool vistara_remote_app_set_work_area(vistara_remote_app *app, vistara_rect area);

/// The session's RemoteApp state, from shim.c, or NULL outside RemoteApp.
vistara_remote_app *vistara_remote_app_for(rdpContext *context);

#endif
