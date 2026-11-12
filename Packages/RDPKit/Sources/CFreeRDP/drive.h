#ifndef VISTARA_DRIVE_H
#define VISTARA_DRIVE_H

// Shared folders: FreeRDP's drive service, with two additions. Only folders
// given by an absolute path are shared, never FreeRDP's wildcards for all
// drives, the home folder, or drives plugged in later. And a folder shared
// read-only refuses every request that would change it, which FreeRDP's drive
// service cannot do on its own.

#include <stdatomic.h>
#include <stdbool.h>

// rdpdr.h pulls in WinPR's interlocked lists, deprecated since WinPR 3.27
// but still used by the header itself.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/channels/rdpdr.h>
#pragma clang diagnostic pop

/// The name rdpdr asks the channel loader for to share a folder, as in
/// FreeRDP's devman.c, which does not publish it.
#define VISTARA_DRIVE_SERVICE_NAME "drive"

/// The drive service entry point that FreeRDP finds under VISTARA_DRIVE_SERVICE_NAME.
UINT VCAPITYPE vistara_drive_service_entry(PDEVICE_SERVICE_ENTRY_POINTS entry_points);

/// Whether the session behind `context` shares the folder at `path`
/// read-only. Implemented in shim.c.
bool vistara_drive_is_read_only(rdpContext *context, const char *path);

/// Requests refused because they would have changed a read-only folder, in
/// all sessions. For tests.
extern atomic_uint_fast64_t vistara_drive_refused_requests;

#endif
