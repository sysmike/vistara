#include "printer.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <freerdp/channels/rdpdr.h>

// MARK: Spool

/// How many documents may be arriving at once.
#define VISTARA_PRINT_JOBS 8u
/// Where in a document "%PDF-" may start ([ISO 32000-2] 7.5.2 lets readers
/// accept it within the first kilobyte).
#define VISTARA_PDF_HEAD 1024u

typedef struct {
    bool used;
    uint32_t id;
    int fd;
    char *path;
    uint64_t size;
    bool too_large;
    uint8_t head[VISTARA_PDF_HEAD];
    size_t head_length;
} vistara_print_job;

struct vistara_print_spool {
    pthread_mutex_t lock;
    char *folder;
    uint64_t limit;
    uint64_t count;
    vistara_print_job jobs[VISTARA_PRINT_JOBS];
    vistara_printed_document *done;
    size_t done_count;
    void (*notify)(void *context);
    void *notify_context;
};

vistara_print_spool *vistara_print_spool_new(const char *folder, uint64_t limit) {
    if (mkdir(folder, 0700) != 0 && errno != EEXIST) {
        return NULL;
    }
    vistara_print_spool *spool = calloc(1, sizeof(*spool));
    if (!spool) {
        return NULL;
    }
    spool->folder = strdup(folder);
    if (!spool->folder) {
        free(spool);
        return NULL;
    }
    spool->limit = limit;
    pthread_mutex_init(&spool->lock, NULL);
    return spool;
}

/// Tells `notify` whenever a document ended.
void vistara_print_spool_set_notify(vistara_print_spool *spool, void (*notify)(void *), void *context) {
    pthread_mutex_lock(&spool->lock);
    spool->notify = notify;
    spool->notify_context = context;
    pthread_mutex_unlock(&spool->lock);
}

static void discard_job(vistara_print_job *job) {
    if (job->fd >= 0) {
        (void)close(job->fd);
    }
    if (job->path) {
        (void)unlink(job->path);
    }
    free(job->path);
    *job = (vistara_print_job){0};
}

void vistara_printed_documents_free(vistara_printed_document *documents, size_t count) {
    for (size_t index = 0; documents && index < count; index++) {
        free(documents[index].path);
    }
    free(documents);
}

void vistara_print_spool_free(vistara_print_spool *spool) {
    if (!spool) {
        return;
    }
    for (size_t index = 0; index < VISTARA_PRINT_JOBS; index++) {
        if (spool->jobs[index].used) {
            discard_job(&spool->jobs[index]);
        }
    }
    for (size_t index = 0; index < spool->done_count; index++) {
        if (spool->done[index].path) {
            (void)unlink(spool->done[index].path);
        }
    }
    vistara_printed_documents_free(spool->done, spool->done_count);
    pthread_mutex_destroy(&spool->lock);
    free(spool->folder);
    free(spool);
}

static vistara_print_job *find_job(vistara_print_spool *spool, uint32_t id) {
    for (size_t index = 0; index < VISTARA_PRINT_JOBS; index++) {
        if (spool->jobs[index].used && spool->jobs[index].id == id) {
            return &spool->jobs[index];
        }
    }
    return NULL;
}

bool vistara_print_spool_open(vistara_print_spool *spool, uint32_t id) {
    pthread_mutex_lock(&spool->lock);
    // A free slot, unless a document with this id is still arriving.
    vistara_print_job *job = NULL;
    for (size_t index = 0; !find_job(spool, id) && !job && index < VISTARA_PRINT_JOBS; index++) {
        if (!spool->jobs[index].used) {
            job = &spool->jobs[index];
        }
    }
    bool opened = false;
    if (job) {
        char name[32];
        (void)snprintf(name, sizeof(name), "job-%llu", (unsigned long long)++spool->count);
        const size_t length = strlen(spool->folder) + 1 + strlen(name) + 1;
        char *path = malloc(length);
        if (path) {
            (void)snprintf(path, length, "%s/%s", spool->folder, name);
            const int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (fd >= 0) {
                *job = (vistara_print_job){.used = true, .id = id, .fd = fd, .path = path};
                opened = true;
            } else {
                free(path);
            }
        }
    }
    pthread_mutex_unlock(&spool->lock);
    return opened;
}

static bool write_all(int fd, const uint8_t *data, size_t length) {
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

bool vistara_print_spool_write(vistara_print_spool *spool, uint32_t id, const uint8_t *data, size_t length) {
    pthread_mutex_lock(&spool->lock);
    vistara_print_job *job = find_job(spool, id);
    bool written = false;
    if (job && !job->too_large) {
        if (job->size + length > spool->limit) {
            // Past the limit: what arrived so far goes, and so does the rest.
            job->too_large = true;
            (void)close(job->fd);
            job->fd = -1;
            (void)unlink(job->path);
            job->size = spool->limit;
        } else if (write_all(job->fd, data, length)) {
            const size_t room = VISTARA_PDF_HEAD - job->head_length;
            const size_t kept = length < room ? length : room;
            memcpy(job->head + job->head_length, data, kept);
            job->head_length += kept;
            job->size += length;
            written = true;
        }
    }
    pthread_mutex_unlock(&spool->lock);
    return written;
}

static bool starts_like_pdf(const vistara_print_job *job) {
    static const char marker[] = "%PDF-";
    const size_t marker_length = sizeof(marker) - 1;
    for (size_t index = 0; index + marker_length <= job->head_length; index++) {
        if (memcmp(job->head + index, marker, marker_length) == 0) {
            return true;
        }
    }
    return false;
}

void vistara_print_spool_close(vistara_print_spool *spool, uint32_t id) {
    pthread_mutex_lock(&spool->lock);
    vistara_print_job *job = find_job(spool, id);
    void (*notify)(void *) = NULL;
    void *context = NULL;
    vistara_printed_document *done =
        job ? realloc(spool->done, (spool->done_count + 1) * sizeof(*spool->done)) : NULL;
    if (job && done) {
        spool->done = done;
        vistara_printed_document *document = &spool->done[spool->done_count++];
        *document = (vistara_printed_document){.size = job->size};
        if (job->too_large) {
            document->kind = VISTARA_PRINTED_TOO_LARGE;
        } else if (!starts_like_pdf(job)) {
            document->kind = VISTARA_PRINTED_NOT_PDF;
        } else {
            document->kind = VISTARA_PRINTED_PDF;
            // The file is the taker's now: not removed with the job.
            document->path = job->path;
            job->path = NULL;
        }
        notify = spool->notify;
        context = spool->notify_context;
    }
    if (job) {
        discard_job(job);
    }
    pthread_mutex_unlock(&spool->lock);
    if (notify) {
        notify(context);
    }
}

bool vistara_print_spool_take(vistara_print_spool *spool, vistara_printed_document **documents, size_t *count) {
    pthread_mutex_lock(&spool->lock);
    *documents = spool->done;
    *count = spool->done_count;
    spool->done = NULL;
    spool->done_count = 0;
    pthread_mutex_unlock(&spool->lock);
    return *count > 0;
}

// MARK: Registry

#define VISTARA_PRINT_SESSIONS 64u

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    uint32_t id;
    vistara_print_spool *spool;
} registry[VISTARA_PRINT_SESSIONS];
static uint32_t registry_last_id = 0;

uint32_t vistara_printer_register(vistara_print_spool *spool) {
    pthread_mutex_lock(&registry_lock);
    uint32_t id = 0;
    for (size_t index = 0; index < VISTARA_PRINT_SESSIONS; index++) {
        if (registry[index].id == 0) {
            registry_last_id = registry_last_id == UINT32_MAX ? 1 : registry_last_id + 1;
            id = registry_last_id;
            registry[index].id = id;
            registry[index].spool = spool;
            break;
        }
    }
    pthread_mutex_unlock(&registry_lock);
    return id;
}

void vistara_printer_unregister(uint32_t id) {
    pthread_mutex_lock(&registry_lock);
    for (size_t index = 0; id != 0 && index < VISTARA_PRINT_SESSIONS; index++) {
        if (registry[index].id == id) {
            registry[index].id = 0;
            registry[index].spool = NULL;
        }
    }
    pthread_mutex_unlock(&registry_lock);
}

/// The spool for a device whose driver name ends in ":vistara-<id>".
static vistara_print_spool *registered_spool(const char *driver_name) {
    const char *suffix = driver_name ? strstr(driver_name, ":" VISTARA_PRINTER_SUBSYSTEM "-") : NULL;
    if (!suffix) {
        return NULL;
    }
    const unsigned long id = strtoul(suffix + strlen(":" VISTARA_PRINTER_SUBSYSTEM "-"), NULL, 10);
    vistara_print_spool *spool = NULL;
    pthread_mutex_lock(&registry_lock);
    for (size_t index = 0; id != 0 && index < VISTARA_PRINT_SESSIONS; index++) {
        if (registry[index].id == id) {
            spool = registry[index].spool;
        }
    }
    pthread_mutex_unlock(&registry_lock);
    return spool;
}

// MARK: Backend

typedef struct {
    rdpPrinterDriver driver;
    size_t references;
    vistara_print_spool *spool;
} vistara_printer_driver;

typedef struct {
    rdpPrintJob job;
    vistara_print_spool *spool;
} vistara_printer_job;

typedef struct {
    rdpPrinter printer;
    vistara_printer_job *current;
} vistara_printer;

static vistara_print_spool *spool_of(rdpPrinter *printer) {
    return ((vistara_printer_driver *)printer->backend)->spool;
}

static UINT job_write(rdpPrintJob *job, const BYTE *data, size_t size) {
    vistara_printer_job *own = (vistara_printer_job *)job;
    return vistara_print_spool_write(own->spool, job->id, data, size) ? CHANNEL_RC_OK : ERROR_DISK_FULL;
}

static void job_close(rdpPrintJob *job) {
    vistara_printer_job *own = (vistara_printer_job *)job;
    vistara_print_spool_close(own->spool, job->id);
    vistara_printer *printer = (vistara_printer *)job->printer;
    if (printer->current == own) {
        printer->current = NULL;
    }
    free(own);
}

static rdpPrintJob *printer_create_job(rdpPrinter *printer, UINT32 id) {
    vistara_printer *own = (vistara_printer *)printer;
    vistara_print_spool *spool = spool_of(printer);
    if (own->current || !spool || !vistara_print_spool_open(spool, id)) {
        return NULL;
    }
    vistara_printer_job *job = calloc(1, sizeof(*job));
    if (!job) {
        vistara_print_spool_close(spool, id);
        return NULL;
    }
    job->job.id = id;
    job->job.printer = printer;
    job->job.Write = job_write;
    job->job.Close = job_close;
    job->spool = spool;
    own->current = job;
    return &job->job;
}

static rdpPrintJob *printer_find_job(rdpPrinter *printer, UINT32 id) {
    vistara_printer *own = (vistara_printer *)printer;
    return own->current && own->current->job.id == id ? &own->current->job : NULL;
}

static void printer_add_ref(rdpPrinter *printer) {
    printer->references++;
}

static void printer_release_ref(rdpPrinter *printer) {
    if (printer->references > 1) {
        printer->references--;
        return;
    }
    vistara_printer *own = (vistara_printer *)printer;
    // A job the remote computer never closed is removed with the session's spool.
    free(own->current);
    if (printer->backend) {
        printer->backend->ReleaseRef(printer->backend);
    }
    free(printer->name);
    free(printer->driver);
    free(printer);
}

static rdpPrinter *driver_get_printer(rdpPrinterDriver *driver, const char *name, const char *driver_name,
                                      BOOL is_default) {
    vistara_printer *printer = calloc(1, sizeof(*printer));
    if (!printer) {
        return NULL;
    }
    printer->printer.backend = driver;
    driver->AddRef(driver);
    printer->printer.name = strdup(name ? name : VISTARA_PRINTER_NAME);
    printer->printer.driver = strdup(driver_name ? driver_name : VISTARA_PRINTER_DRIVER);
    printer->printer.is_default = is_default;
    printer->printer.CreatePrintJob = printer_create_job;
    printer->printer.FindPrintJob = printer_find_job;
    printer->printer.AddRef = printer_add_ref;
    printer->printer.ReleaseRef = printer_release_ref;
    printer->printer.references = 1;
    if (!printer->printer.name || !printer->printer.driver) {
        printer_release_ref(&printer->printer);
        return NULL;
    }
    return &printer->printer;
}

/// Only the printer the device names: no other printer is ever offered.
static rdpPrinter **driver_enum_printers(rdpPrinterDriver *driver) {
    (void)driver;
    return calloc(1, sizeof(rdpPrinter *));
}

static void driver_release_enum_printers(rdpPrinter **printers) {
    for (rdpPrinter **current = printers; current && *current; current++) {
        (*current)->ReleaseRef(*current);
    }
    free((void *)printers);
}

static void driver_add_ref(rdpPrinterDriver *driver) {
    ((vistara_printer_driver *)driver)->references++;
}

static void driver_release_ref(rdpPrinterDriver *driver) {
    vistara_printer_driver *own = (vistara_printer_driver *)driver;
    if (own->references > 1) {
        own->references--;
        return;
    }
    free(own);
}

static void driver_set_device(rdpPrinterDriver *driver, const RDPDR_PRINTER *device) {
    ((vistara_printer_driver *)driver)->spool = registered_spool(device ? device->DriverName : NULL);
}

UINT VCAPITYPE vistara_printer_backend_entry(void *argument) {
    rdpPrinterDriver **result = argument;
    vistara_printer_driver *driver = calloc(1, sizeof(*driver));
    if (!result || !driver) {
        free(driver);
        return CHANNEL_RC_NO_MEMORY;
    }
    driver->references = 1;
    driver->driver.EnumPrinters = driver_enum_printers;
    driver->driver.ReleaseEnumPrinters = driver_release_enum_printers;
    driver->driver.GetPrinter = driver_get_printer;
    driver->driver.AddRef = driver_add_ref;
    driver->driver.ReleaseRef = driver_release_ref;
    driver->driver.SetDeviceContext = driver_set_device;
    *result = &driver->driver;
    return CHANNEL_RC_OK;
}
