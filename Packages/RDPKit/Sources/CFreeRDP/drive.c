#include "drive.h"

#include <string.h>

#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/settings.h>
#include <winpr/cast.h>
#include <winpr/nt.h>
#include <winpr/stream.h>
#include <winpr/wlog.h>
#include <winpr/wtsapi.h>

#define TAG "com.vistara.drive"

// [MS-SMB2] 2.2.13: the create request's fields Vistara looks at.
#define VISTARA_FILE_OPEN 0x00000001u
#define VISTARA_FILE_DELETE_ON_CLOSE 0x00001000u
// Every access right that changes a file, its attributes, or its folder.
#define VISTARA_WRITE_ACCESS                                                                            \
    (0x00000002u /* FILE_WRITE_DATA */ | 0x00000004u /* FILE_APPEND_DATA */ |                           \
     0x00000010u /* FILE_WRITE_EA */ | 0x00000040u /* FILE_DELETE_CHILD */ |                            \
     0x00000100u /* FILE_WRITE_ATTRIBUTES */ | 0x00010000u /* DELETE */ | 0x00040000u /* WRITE_DAC */ | \
     0x00080000u /* WRITE_OWNER */ | 0x10000000u /* GENERIC_ALL */ | 0x40000000u /* GENERIC_WRITE */)

atomic_uint_fast64_t vistara_drive_refused_requests;

// FreeRDP's drive service handles requests for every drive with one function,
// which read-only drives call for what they let through.
static _Atomic(pcIRPRequest) drive_irp_request;

// FreeRDP's device registration, and whether the drive is read-only, while
// its drive service registers a drive. The service registers before it
// returns, on this thread.
static _Thread_local pcRegisterDevice register_device;
static _Thread_local bool registering_read_only;

/// Whether a create request's path has a ".." component, which would climb
/// out of the folder.
static bool leaves_folder(IRP *irp) {
    if (irp->MajorFunction != IRP_MJ_CREATE) {
        return false;
    }
    // Seven fields before the path, the last its length in bytes.
    if (Stream_GetRemainingLength(irp->input) < 6 * 4 + 8) {
        return true;
    }
    const BYTE *request = Stream_ConstPointer(irp->input);
    const UINT32 length = (UINT32)request[28] | (UINT32)request[29] << 8 | (UINT32)request[30] << 16 |
                          (UINT32)request[31] << 24;
    if (Stream_GetRemainingLength(irp->input) - 32 < length) {
        return true;
    }
    // UTF-16LE: a component of exactly two dots between separators.
    const BYTE *path = request + 32;
    size_t component = 0;
    bool only_dots = true;
    for (size_t index = 0; index + 1 < length; index += 2) {
        const UINT16 unit = (UINT16)(path[index] | path[index + 1] << 8);
        if (unit == '\\' || unit == '/' || unit == 0) {
            if (component == 2 && only_dots) {
                return true;
            }
            component = 0;
            only_dots = true;
            if (unit == 0) {
                break;
            }
            continue;
        }
        component++;
        only_dots = only_dots && unit == '.';
    }
    return component == 2 && only_dots;
}

/// Whether a request would change the folder.
static bool changes_folder(IRP *irp) {
    switch (irp->MajorFunction) {
    case IRP_MJ_WRITE:
    case IRP_MJ_SET_INFORMATION:
    case IRP_MJ_SET_VOLUME_INFORMATION:
        return true;
    case IRP_MJ_CREATE: {
        // DesiredAccess, AllocationSize, FileAttributes, SharedAccess,
        // CreateDisposition, CreateOptions. Read without moving the stream,
        // which the drive service reads again.
        if (Stream_GetRemainingLength(irp->input) < 6 * 4 + 8) {
            return true;
        }
        const size_t position = Stream_GetPosition(irp->input);
        const UINT32 access = Stream_Get_UINT32(irp->input);
        const UINT64 allocation_size = Stream_Get_UINT64(irp->input);
        Stream_Seek(irp->input, 8);
        const UINT32 disposition = Stream_Get_UINT32(irp->input);
        const UINT32 options = Stream_Get_UINT32(irp->input);
        Stream_SetPosition(irp->input, position);
        // Opening what exists, to read it: anything else creates, replaces,
        // or deletes.
        return (access & VISTARA_WRITE_ACCESS) != 0 || disposition != VISTARA_FILE_OPEN ||
               (options & VISTARA_FILE_DELETE_ON_CLOSE) != 0 || allocation_size != 0;
    }
    default:
        return false;
    }
}

/// Answers a request that would change a read-only folder with "access
/// denied", in the response layout the request's kind has.
static UINT refuse(IRP *irp) {
    atomic_fetch_add(&vistara_drive_refused_requests, 1);
    irp->IoStatus = STATUS_ACCESS_DENIED;
    if (!Stream_EnsureRemainingCapacity(irp->output, 5)) {
        irp->Discard(irp);
        return CHANNEL_RC_NO_MEMORY;
    }
    switch (irp->MajorFunction) {
    case IRP_MJ_CREATE:
        Stream_Write_UINT32(irp->output, 0); // FileId
        Stream_Write_UINT8(irp->output, 0);  // Information
        break;
    case IRP_MJ_WRITE:
        Stream_Write_UINT32(irp->output, 0); // Length
        Stream_Write_UINT8(irp->output, 0);  // Padding
        break;
    default:
        Stream_Write_UINT32(irp->output, 0); // Length
        break;
    }
    return irp->Complete(irp);
}

static UINT guarded_irp_request(DEVICE *device, IRP *irp) {
    if (leaves_folder(irp)) {
        return refuse(irp);
    }
    return atomic_load(&drive_irp_request)(device, irp);
}

static UINT read_only_irp_request(DEVICE *device, IRP *irp) {
    if (leaves_folder(irp) || changes_folder(irp)) {
        return refuse(irp);
    }
    return atomic_load(&drive_irp_request)(device, irp);
}

static UINT register_guarded(DEVMAN *devman, DEVICE *device) {
    pcIRPRequest expected = NULL;
    if (!atomic_compare_exchange_strong(&drive_irp_request, &expected, device->IRPRequest) &&
        expected != device->IRPRequest) {
        // Not the handler the other drives use: better not to share the
        // folder than to share it writable.
        WLog_ERR(TAG, "unexpected drive service; the folder is not shared");
        return ERROR_INTERNAL_ERROR;
    }
    device->IRPRequest = registering_read_only ? read_only_irp_request : guarded_irp_request;
    return register_device(devman, device);
}

UINT VCAPITYPE vistara_drive_service_entry(PDEVICE_SERVICE_ENTRY_POINTS entry_points) {
    const RDPDR_DRIVE *drive = (const RDPDR_DRIVE *)entry_points->device;
    // Only a folder named by its absolute path: never "*" (all drives), "%"
    // (the home folder), or "DynamicDrives" (drives plugged in later).
    if (!drive || drive->device.Type != RDPDR_DTYP_FILESYSTEM || !drive->Path || drive->Path[0] != '/') {
        WLog_ERR(TAG, "refused a drive that is not one folder");
        return ERROR_INVALID_PARAMETER;
    }
    PDEVICE_SERVICE_ENTRY service = WINPR_FUNC_PTR_CAST(
        freerdp_channels_load_static_addin_entry(VISTARA_DRIVE_SERVICE_NAME, NULL, "DeviceServiceEntry", 0),
        PDEVICE_SERVICE_ENTRY);
    if (!service) {
        return ERROR_INTERNAL_ERROR;
    }
    DEVICE_SERVICE_ENTRY_POINTS guarded = *entry_points;
    register_device = entry_points->RegisterDevice;
    registering_read_only = vistara_drive_is_read_only(entry_points->rdpcontext, drive->Path);
    guarded.RegisterDevice = register_guarded;
    const UINT result = service(&guarded);
    register_device = NULL;
    return result;
}
