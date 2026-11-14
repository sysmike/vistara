#ifndef VISTARA_CLIPBOARD_FILES_H
#define VISTARA_CLIPBOARD_FILES_H

// Files through the clipboard ([MS-RDPECLIP] 3.1.5.4.5 to 3.1.5.4.8), both
// ways, for one session. FreeRDP's own file context (client_cliprdr_file.c)
// is not used: it follows symbolic links when it lists a folder and opens
// files by name when asked, and its macOS part waits on the main thread.
//
// Mac to remote computer: the files offered are listed once, by the caller.
// A contents request is answered from a regular file opened without
// following symbolic links, only if it is still the file that was listed.
//
// Remote computer to Mac: the remote computer's list is kept, and files are
// fetched on request, one request at a time, each answer asking for the next.
//
// Locking ([MS-RDPECLIP] 2.2.4.6 and 2.2.4.7), where the other side supports
// it: the remote computer may lock what this Mac offers, which keeps that
// offer for the requests naming the lock, whatever is copied meanwhile. A
// fetch locks what the remote computer offers until it ends, so it is not
// ended by the remote computer copying something else.
//
// Nothing here logs a file's name. Every function except the
// vistara_file_list_* ones is called with the session's clipboard lock held.

#include "CFreeRDP.h"

#include <freerdp/client/cliprdr.h>

/// The format IDs this client gives the two file formats it offers. Any
/// registered ID (0xC000 and up) will do: the names are what count.
#define VISTARA_FORMAT_FILE_LIST 0xC0F0u
#define VISTARA_FORMAT_FILE_CONTENTS 0xC0F1u

/// How much of a file one request asks for.
#define VISTARA_FILE_CHUNK (1024u * 1024u)

/// The general capability flags for copying files that this client supports.
#define VISTARA_FILE_CAPABILITIES \
    (CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS | CB_HUGE_FILE_SUPPORT_ENABLED | CB_CAN_LOCK_CLIPDATA)

/// How many locks of this Mac's offers the remote computer may hold at once.
/// A lock beyond them replaces the oldest.
#define VISTARA_MAX_LOCKS 16u

typedef struct {
    char *name;
    char *path;
    uint64_t size;
    bool is_folder;
    uint64_t device;
    uint64_t inode;
} vistara_offered_file;

/// An offer the remote computer locked, kept under its ID.
typedef struct {
    bool used;
    uint32_t clip_data_id;
    vistara_offered_file *files;
    size_t count;
} vistara_locked_offer;

typedef struct {
    uint64_t size;
    bool has_size;
    bool is_folder;
} vistara_listed_file;

typedef struct {
    uint32_t list_index;
    char *destination;
    uint64_t size;
    bool has_size;
} vistara_fetch_job;

typedef struct {
    // Mac to remote computer.
    vistara_offered_file *offered;
    size_t offered_count;
    // The offers the remote computer locked.
    vistara_locked_offer locks[VISTARA_MAX_LOCKS];
    size_t next_lock_slot;
    // The last file read, kept open for the next part.
    int open_fd;
    const vistara_offered_file *open_file;
    uint64_t bytes_sent;

    // Remote computer to Mac: the current list, and the one not taken yet.
    uint64_t list_id;
    vistara_listed_file *listed;
    size_t listed_count;
    bool has_untaken;
    vistara_remote_file *untaken;
    size_t untaken_count;

    // The fetch, if any.
    vistara_fetch_job *jobs;
    size_t job_count;
    size_t job;
    uint64_t offset;
    int fd;
    uint32_t stream_id;
    bool asking_size;
    vistara_fetch_status status;
    // The lock the fetch holds, if any (0 for none), and the channel to
    // release it on.
    uint32_t fetch_lock;
    uint32_t last_lock;
    CliprdrClientContext *fetch_clipboard;
} vistara_clipboard_files;

void vistara_files_init(vistara_clipboard_files *files);
void vistara_files_free(vistara_clipboard_files *files);

/// Mac to remote computer.
bool vistara_files_set_offer(vistara_clipboard_files *files, const vistara_local_file *offer, size_t count);
UINT vistara_files_answer_list_request(vistara_clipboard_files *files, CliprdrClientContext *clipboard,
                                       uint32_t flags);
UINT vistara_files_answer_contents_request(vistara_clipboard_files *files, CliprdrClientContext *clipboard,
                                           const CLIPRDR_FILE_CONTENTS_REQUEST *request);
/// The remote computer locks or unlocks what this Mac offers now.
void vistara_files_lock(vistara_clipboard_files *files, uint32_t clip_data_id);
void vistara_files_unlock(vistara_clipboard_files *files, uint32_t clip_data_id);

/// Remote computer to Mac. `has_files` says whether the new clipboard has a
/// file list, which arrives later through vistara_files_take_list().
void vistara_files_remote_changed(vistara_clipboard_files *files, bool has_files);
/// `data` is NULL when the remote computer did not send its list.
void vistara_files_take_list(vistara_clipboard_files *files, const BYTE *data, UINT32 length);
/// With `can_lock`, the fetch locks the remote computer's data until it ends.
bool vistara_files_start_fetch(vistara_clipboard_files *files, CliprdrClientContext *clipboard, uint64_t list_id,
                               const vistara_fetch_item *items, size_t count, bool can_lock);
void vistara_files_contents_response(vistara_clipboard_files *files, CliprdrClientContext *clipboard,
                                     const CLIPRDR_FILE_CONTENTS_RESPONSE *response);
/// Ends a running fetch with `state`, removing the file it was writing.
void vistara_files_end_fetch(vistara_clipboard_files *files, vistara_fetch_state state, int32_t os_error);
/// The clipboard channel closed.
void vistara_files_channel_closed(vistara_clipboard_files *files);

#endif
