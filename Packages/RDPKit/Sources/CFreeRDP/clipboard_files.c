#include "clipboard_files.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/file.h>
#include <winpr/shell.h>
#include <winpr/string.h>

/// The most a contents request may ask for in one go.
#define VISTARA_MAX_CONTENTS_REQUEST (8u * 1024u * 1024u)

/// The most files a list may hold, from either side.
#define VISTARA_MAX_LISTED_FILES 100000u

// MARK: File lists

static void free_offer(vistara_clipboard_files *files) {
    for (size_t index = 0; index < files->offered_count; index++) {
        free(files->offered[index].name);
        free(files->offered[index].path);
    }
    free(files->offered);
    files->offered = NULL;
    files->offered_count = 0;
    if (files->open_fd >= 0) {
        (void)close(files->open_fd);
        files->open_fd = -1;
    }
}

/// The packed file list for `count` files. Each name must fit in a file
/// descriptor; a file of 4 GB or more needs `huge` (CB_HUGE_FILE_SUPPORT_ENABLED).
static UINT encode_list(const vistara_local_file *offer, size_t count, bool huge, BYTE **data, UINT32 *length) {
    if (count == 0 || count > VISTARA_MAX_LISTED_FILES) {
        return ERROR_BAD_ARGUMENTS;
    }
    FILEDESCRIPTORW *descriptors = calloc(count, sizeof(*descriptors));
    if (!descriptors) {
        return ERROR_NOT_ENOUGH_MEMORY;
    }
    for (size_t index = 0; index < count; index++) {
        FILEDESCRIPTORW *descriptor = &descriptors[index];
        const vistara_local_file *file = &offer[index];
        descriptor->dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_SHOWPROGRESSUI;
        descriptor->dwFileAttributes = file->is_folder ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
        const uint64_t size = file->is_folder ? 0 : file->size;
        descriptor->nFileSizeHigh = (DWORD)(size >> 32);
        descriptor->nFileSizeLow = (DWORD)(size & 0xFFFFFFFFu);
        if (ConvertUtf8ToWChar(file->name, descriptor->cFileName, ARRAYSIZE(descriptor->cFileName)) <= 0) {
            free(descriptors);
            return ERROR_BAD_ARGUMENTS;
        }
    }
    const UINT32 flags = CB_STREAM_FILECLIP_ENABLED | (huge ? CB_HUGE_FILE_SUPPORT_ENABLED : 0);
    const UINT result = cliprdr_serialize_file_list_ex(flags, descriptors, (UINT32)count, data, length);
    free(descriptors);
    return result;
}

/// Reads a packed file list. Names are passed on as sent: RDPKit checks each
/// one before it becomes a path (RDPClipboardFileName.fromRemote).
static bool decode_list(const BYTE *data, UINT32 length, vistara_remote_file **out, vistara_listed_file **listed,
                        size_t *count) {
    *out = NULL;
    *count = 0;
    if (listed) {
        *listed = NULL;
    }
    FILEDESCRIPTORW *descriptors = NULL;
    UINT32 found = 0;
    if (cliprdr_parse_file_list(data, length, &descriptors, &found) != CHANNEL_RC_OK ||
        found > VISTARA_MAX_LISTED_FILES) {
        free(descriptors);
        return false;
    }
    vistara_remote_file *files = calloc(found ? found : 1, sizeof(*files));
    vistara_listed_file *sizes = listed ? calloc(found ? found : 1, sizeof(*sizes)) : NULL;
    if (!files || (listed && !sizes)) {
        free(files);
        free(sizes);
        free(descriptors);
        return false;
    }
    for (UINT32 index = 0; index < found; index++) {
        const FILEDESCRIPTORW *descriptor = &descriptors[index];
        vistara_remote_file *file = &files[index];
        const size_t units = _wcsnlen(descriptor->cFileName, ARRAYSIZE(descriptor->cFileName));
        file->name = ConvertWCharNToUtf8Alloc(descriptor->cFileName, units, NULL);
        if (!file->name) {
            file->name = calloc(1, 1);
        }
        file->is_folder = (descriptor->dwFlags & FD_ATTRIBUTES) &&
                          (descriptor->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
        file->has_size = !file->is_folder && (descriptor->dwFlags & FD_FILESIZE);
        file->size = file->has_size ? ((uint64_t)descriptor->nFileSizeHigh << 32) | descriptor->nFileSizeLow : 0;
        if (sizes) {
            sizes[index] = (vistara_listed_file){
                .size = file->size, .has_size = file->has_size, .is_folder = file->is_folder};
        }
        if (!file->name) {
            vistara_remote_files_free(files, index);
            free(sizes);
            free(descriptors);
            return false;
        }
    }
    free(descriptors);
    *out = files;
    *count = found;
    if (listed) {
        *listed = sizes;
    }
    return true;
}

uint8_t *vistara_file_list_encode(const vistara_local_file *files, size_t count, size_t *length) {
    BYTE *data = NULL;
    UINT32 encoded = 0;
    if (!files || encode_list(files, count, true, &data, &encoded) != CHANNEL_RC_OK) {
        return NULL;
    }
    *length = encoded;
    return data;
}

bool vistara_file_list_decode(const uint8_t *data, size_t length, vistara_remote_file **files, size_t *count) {
    if (length > UINT32_MAX) {
        return false;
    }
    return decode_list(data, (UINT32)length, files, NULL, count);
}

void vistara_remote_files_free(vistara_remote_file *files, size_t count) {
    if (!files) {
        return;
    }
    for (size_t index = 0; index < count; index++) {
        free(files[index].name);
    }
    free(files);
}

// MARK: Lifecycle

void vistara_files_init(vistara_clipboard_files *files) {
    memset(files, 0, sizeof(*files));
    files->open_fd = -1;
    files->fd = -1;
}

static void free_jobs(vistara_clipboard_files *files) {
    for (size_t index = 0; index < files->job_count; index++) {
        free(files->jobs[index].destination);
    }
    free(files->jobs);
    files->jobs = NULL;
    files->job_count = 0;
}

static void free_untaken(vistara_clipboard_files *files) {
    vistara_remote_files_free(files->untaken, files->untaken_count);
    files->untaken = NULL;
    files->untaken_count = 0;
    files->has_untaken = false;
}

void vistara_files_free(vistara_clipboard_files *files) {
    vistara_files_end_fetch(files, VISTARA_FETCH_CHANNEL_CLOSED, 0);
    free_offer(files);
    free_untaken(files);
    free(files->listed);
    files->listed = NULL;
    free_jobs(files);
}

// MARK: Mac to remote computer

bool vistara_files_set_offer(vistara_clipboard_files *files, const vistara_local_file *offer, size_t count) {
    free_offer(files);
    if (count == 0 || count > VISTARA_MAX_LISTED_FILES) {
        return count == 0;
    }
    files->offered = calloc(count, sizeof(*files->offered));
    if (!files->offered) {
        return false;
    }
    files->offered_count = count;
    for (size_t index = 0; index < count; index++) {
        vistara_offered_file *file = &files->offered[index];
        file->name = strdup(offer[index].name);
        file->path = strdup(offer[index].is_folder ? "" : offer[index].path);
        file->size = offer[index].size;
        file->is_folder = offer[index].is_folder;
        file->device = offer[index].device;
        file->inode = offer[index].inode;
        if (!file->name || !file->path) {
            free_offer(files);
            return false;
        }
    }
    return true;
}

UINT vistara_files_answer_list_request(vistara_clipboard_files *files, CliprdrClientContext *clipboard,
                                       uint32_t flags) {
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    BYTE *data = NULL;
    UINT32 length = 0;
    vistara_local_file *offer = calloc(files->offered_count ? files->offered_count : 1, sizeof(*offer));
    if (offer && files->offered_count > 0) {
        for (size_t index = 0; index < files->offered_count; index++) {
            const vistara_offered_file *file = &files->offered[index];
            offer[index] = (vistara_local_file){
                .name = file->name, .path = file->path, .size = file->size, .is_folder = file->is_folder};
        }
        const bool huge = (flags & CB_HUGE_FILE_SUPPORT_ENABLED) != 0;
        if (encode_list(offer, files->offered_count, huge, &data, &length) == CHANNEL_RC_OK) {
            response.common.msgFlags = CB_RESPONSE_OK;
            response.common.dataLen = length;
            response.requestedFormatData = data;
            files->bytes_sent += length;
        }
    }
    free(offer);
    const UINT result = clipboard->ClientFormatDataResponse(clipboard, &response);
    free(data);
    return result;
}

static UINT send_contents(CliprdrClientContext *clipboard, uint32_t stream_id, const void *data, uint32_t length) {
    CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.streamId = stream_id;
    response.cbRequested = data ? length : 0;
    response.requestedData = data;
    return clipboard->ClientFileContentsResponse(clipboard, &response);
}

/// The offered file at `index`, opened for reading: a regular file, reached
/// without following a symbolic link, and still the one that was listed.
static int open_offered(vistara_clipboard_files *files, size_t index) {
    if (files->open_fd >= 0 && files->open_index == index) {
        return files->open_fd;
    }
    if (files->open_fd >= 0) {
        (void)close(files->open_fd);
        files->open_fd = -1;
    }
    const vistara_offered_file *file = &files->offered[index];
    const int fd = open(file->path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        return -1;
    }
    struct stat status;
    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || (uint64_t)status.st_dev != file->device ||
        (uint64_t)status.st_ino != file->inode) {
        (void)close(fd);
        return -1;
    }
    files->open_fd = fd;
    files->open_index = index;
    return fd;
}

UINT vistara_files_answer_contents_request(vistara_clipboard_files *files, CliprdrClientContext *clipboard,
                                           const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    const bool wants_size = (request->dwFlags & FILECONTENTS_SIZE) != 0;
    const bool wants_range = (request->dwFlags & FILECONTENTS_RANGE) != 0;
    if (request->listIndex >= files->offered_count || files->offered[request->listIndex].is_folder ||
        wants_size == wants_range) {
        return send_contents(clipboard, request->streamId, NULL, 0);
    }
    const int fd = open_offered(files, request->listIndex);
    if (fd < 0) {
        return send_contents(clipboard, request->streamId, NULL, 0);
    }
    struct stat status;
    if (fstat(fd, &status) != 0) {
        return send_contents(clipboard, request->streamId, NULL, 0);
    }
    if (wants_size) {
        BYTE size[8];
        const uint64_t value = (uint64_t)status.st_size;
        for (size_t byte = 0; byte < sizeof(size); byte++) {
            size[byte] = (BYTE)(value >> (8 * byte));
        }
        return send_contents(clipboard, request->streamId, size, sizeof(size));
    }
    const uint64_t offset = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
    uint32_t wanted = request->cbRequested;
    if (wanted > VISTARA_MAX_CONTENTS_REQUEST) {
        wanted = VISTARA_MAX_CONTENTS_REQUEST;
    }
    const uint64_t available = offset < (uint64_t)status.st_size ? (uint64_t)status.st_size - offset : 0;
    if (wanted > available) {
        wanted = (uint32_t)available;
    }
    BYTE *data = malloc(wanted ? wanted : 1);
    if (!data) {
        return send_contents(clipboard, request->streamId, NULL, 0);
    }
    size_t read_so_far = 0;
    while (read_so_far < wanted) {
        const ssize_t got = pread(fd, data + read_so_far, wanted - read_so_far, (off_t)(offset + read_so_far));
        if (got < 0 && errno == EINTR) {
            continue;
        }
        if (got <= 0) {
            break;
        }
        read_so_far += (size_t)got;
    }
    const bool complete = read_so_far == wanted;
    if (complete) {
        files->bytes_sent += wanted;
    }
    const UINT result = send_contents(clipboard, request->streamId, complete ? data : NULL, wanted);
    free(data);
    return result;
}

// MARK: Remote computer to Mac

void vistara_files_remote_changed(vistara_clipboard_files *files, bool has_files) {
    vistara_files_end_fetch(files, VISTARA_FETCH_LIST_CHANGED, 0);
    free(files->listed);
    files->listed = NULL;
    files->listed_count = 0;
    files->list_id += 1;
    free_untaken(files);
    // Without files the list is empty now; with them it follows.
    files->has_untaken = !has_files;
}

void vistara_files_take_list(vistara_clipboard_files *files, const BYTE *data, UINT32 length) {
    free_untaken(files);
    vistara_remote_file *entries = NULL;
    vistara_listed_file *listed = NULL;
    size_t count = 0;
    if (data && decode_list(data, length, &entries, &listed, &count)) {
        free(files->listed);
        files->listed = listed;
        files->listed_count = count;
        files->untaken = entries;
        files->untaken_count = count;
    }
    // A list that could not be read counts as none.
    files->has_untaken = true;
}

static void close_fetched(vistara_clipboard_files *files, bool keep) {
    if (files->fd < 0) {
        return;
    }
    (void)close(files->fd);
    files->fd = -1;
    if (!keep && files->job < files->job_count) {
        (void)unlink(files->jobs[files->job].destination);
    }
}

void vistara_files_end_fetch(vistara_clipboard_files *files, vistara_fetch_state state, int32_t os_error) {
    if (files->status.state != VISTARA_FETCH_RUNNING) {
        return;
    }
    close_fetched(files, false);
    files->status.state = state;
    files->status.os_error = os_error;
    free_jobs(files);
}

void vistara_files_channel_closed(vistara_clipboard_files *files) {
    vistara_files_end_fetch(files, VISTARA_FETCH_CHANNEL_CLOSED, 0);
    if (files->open_fd >= 0) {
        (void)close(files->open_fd);
        files->open_fd = -1;
    }
}

/// Asks for the next part of the current file, or moves on to the next file,
/// until one request is out or everything is fetched.
static void request_next(vistara_clipboard_files *files, CliprdrClientContext *clipboard) {
    while (files->job < files->job_count) {
        vistara_fetch_job *job = &files->jobs[files->job];
        if (files->fd < 0) {
            files->fd = open(job->destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
            if (files->fd < 0) {
                vistara_files_end_fetch(files, VISTARA_FETCH_WRITE_FAILED, errno);
                return;
            }
            files->offset = 0;
        }
        CLIPRDR_FILE_CONTENTS_REQUEST request = {0};
        request.common.msgType = CB_FILECONTENTS_REQUEST;
        request.listIndex = job->list_index;
        if (!job->has_size) {
            files->asking_size = true;
            request.dwFlags = FILECONTENTS_SIZE;
            request.cbRequested = 8;
        } else if (files->offset >= job->size) {
            close_fetched(files, true);
            files->status.files_done += 1;
            files->job += 1;
            continue;
        } else {
            files->asking_size = false;
            const uint64_t left = job->size - files->offset;
            request.dwFlags = FILECONTENTS_RANGE;
            request.nPositionLow = (UINT32)(files->offset & 0xFFFFFFFFu);
            request.nPositionHigh = (UINT32)(files->offset >> 32);
            request.cbRequested = left < VISTARA_FILE_CHUNK ? (UINT32)left : VISTARA_FILE_CHUNK;
        }
        request.streamId = ++files->stream_id;
        if (clipboard->ClientFileContentsRequest(clipboard, &request) != CHANNEL_RC_OK) {
            vistara_files_end_fetch(files, VISTARA_FETCH_REFUSED, 0);
        }
        return;
    }
    files->status.state = VISTARA_FETCH_DONE;
    free_jobs(files);
}

bool vistara_files_start_fetch(vistara_clipboard_files *files, CliprdrClientContext *clipboard, uint64_t list_id,
                               const vistara_fetch_item *items, size_t count) {
    if (files->status.state == VISTARA_FETCH_RUNNING || list_id != files->list_id || !files->listed || count == 0 ||
        count > files->listed_count) {
        return false;
    }
    for (size_t index = 0; index < count; index++) {
        if (items[index].list_index >= files->listed_count || files->listed[items[index].list_index].is_folder) {
            return false;
        }
    }
    free_jobs(files);
    files->jobs = calloc(count, sizeof(*files->jobs));
    if (!files->jobs) {
        return false;
    }
    files->job_count = count;
    vistara_fetch_status status = {.state = VISTARA_FETCH_RUNNING, .file_count = (uint32_t)count};
    for (size_t index = 0; index < count; index++) {
        const vistara_listed_file *listed = &files->listed[items[index].list_index];
        vistara_fetch_job *job = &files->jobs[index];
        job->list_index = items[index].list_index;
        job->size = listed->size;
        job->has_size = listed->has_size;
        job->destination = strdup(items[index].destination);
        if (!job->destination) {
            free_jobs(files);
            return false;
        }
        status.bytes_expected += listed->has_size ? listed->size : 0;
    }
    files->status = status;
    files->job = 0;
    files->offset = 0;
    request_next(files, clipboard);
    return true;
}

static bool write_all(int fd, const BYTE *data, size_t length) {
    while (length > 0) {
        const ssize_t written = write(fd, data, length);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return false;
        }
        data += written;
        length -= (size_t)written;
    }
    return true;
}

void vistara_files_contents_response(vistara_clipboard_files *files, CliprdrClientContext *clipboard,
                                     const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
    // An answer to a fetch that ended, or to an earlier request, is dropped.
    if (files->status.state != VISTARA_FETCH_RUNNING || response->streamId != files->stream_id ||
        files->job >= files->job_count) {
        return;
    }
    if (!(response->common.msgFlags & CB_RESPONSE_OK) || (response->cbRequested > 0 && !response->requestedData)) {
        vistara_files_end_fetch(files, VISTARA_FETCH_REFUSED, 0);
        return;
    }
    vistara_fetch_job *job = &files->jobs[files->job];
    if (files->asking_size) {
        if (response->cbRequested < 8) {
            vistara_files_end_fetch(files, VISTARA_FETCH_REFUSED, 0);
            return;
        }
        uint64_t size = 0;
        for (size_t byte = 0; byte < 8; byte++) {
            size |= (uint64_t)response->requestedData[byte] << (8 * byte);
        }
        job->size = size;
        job->has_size = true;
        files->status.bytes_expected += size;
        request_next(files, clipboard);
        return;
    }
    // Nothing more where the list promised more: the file is not all there.
    if (response->cbRequested == 0) {
        vistara_files_end_fetch(files, VISTARA_FETCH_REFUSED, 0);
        return;
    }
    const uint64_t left = job->size - files->offset;
    const size_t length = response->cbRequested < left ? response->cbRequested : (size_t)left;
    if (!write_all(files->fd, response->requestedData, length)) {
        vistara_files_end_fetch(files, VISTARA_FETCH_WRITE_FAILED, errno);
        return;
    }
    files->offset += length;
    files->status.bytes_received += length;
    request_next(files, clipboard);
}
