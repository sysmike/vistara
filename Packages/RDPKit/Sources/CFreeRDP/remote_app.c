#include "remote_app.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/codec/color.h>
#include <freerdp/rail.h>
#include <freerdp/update.h>
#include <freerdp/window.h>
#include <winpr/string.h>

// FreeRDP announces 3 icon caches of 12 entries each (settings.c); the
// remote computer refers to icons it sent before by those numbers.
#define VISTARA_ICON_CACHES 3
#define VISTARA_ICON_CACHE_ENTRIES 12
// Larger icons are not kept: Windows' largest is 256 pixels square.
#define VISTARA_ICON_MAX_SIDE 256
// An entry that is not cached.
#define VISTARA_ICON_NOT_CACHED 0xFFFF

typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t *pixels;
} icon_image;

typedef struct {
    vistara_remote_window window;
    bool changed;
} window_entry;

struct vistara_remote_app {
    // Window orders arrive on the session thread, RAIL orders on the
    // channel's: everything below is guarded by lock.
    pthread_mutex_t lock;
    RailClientContext *rail;
    void (*wake)(void *);
    void *wake_context;
    // Whether the remote computer's desktop is ready for the program, and
    // whether it was started.
    bool desktop_ready;
    bool started;
    window_entry *windows;
    size_t window_count;
    size_t window_capacity;
    icon_image icon_cache[VISTARA_ICON_CACHES][VISTARA_ICON_CACHE_ENTRIES];
    vistara_remote_app_event *events;
    size_t event_count;
    size_t event_capacity;
};

vistara_remote_app *vistara_remote_app_new(void) {
    vistara_remote_app *app = calloc(1, sizeof(*app));
    if (!app) {
        return NULL;
    }
    if (pthread_mutex_init(&app->lock, NULL) != 0) {
        free(app);
        return NULL;
    }
    return app;
}

static void free_window_fields(vistara_remote_window *window) {
    free(window->title);
    free(window->visible_rects);
    free(window->icon_pixels);
    window->title = NULL;
    window->visible_rects = NULL;
    window->icon_pixels = NULL;
}

void vistara_remote_app_free(vistara_remote_app *app) {
    if (!app) {
        return;
    }
    for (size_t index = 0; index < app->window_count; index++) {
        free_window_fields(&app->windows[index].window);
    }
    free(app->windows);
    for (size_t cache = 0; cache < VISTARA_ICON_CACHES; cache++) {
        for (size_t entry = 0; entry < VISTARA_ICON_CACHE_ENTRIES; entry++) {
            free(app->icon_cache[cache][entry].pixels);
        }
    }
    free(app->events);
    pthread_mutex_destroy(&app->lock);
    free(app);
}

// MARK: Windows

/// The window's entry, made if `create`; NULL without one. Locked.
static window_entry *entry_for(vistara_remote_app *app, uint32_t id, bool create) {
    for (size_t index = 0; index < app->window_count; index++) {
        if (app->windows[index].window.id == id) {
            return &app->windows[index];
        }
    }
    if (!create) {
        return NULL;
    }
    if (app->window_count == app->window_capacity) {
        const size_t capacity = app->window_capacity ? app->window_capacity * 2 : 8;
        window_entry *grown = realloc(app->windows, capacity * sizeof(*grown));
        if (!grown) {
            return NULL;
        }
        app->windows = grown;
        app->window_capacity = capacity;
    }
    window_entry *entry = &app->windows[app->window_count++];
    memset(entry, 0, sizeof(*entry));
    entry->window.id = id;
    return entry;
}

/// A title as the remote computer sends one, UTF-16LE of `length` bytes.
static char *title_from(const RAIL_UNICODE_STRING *title) {
    if (!title->string || title->length == 0) {
        return strdup("");
    }
    size_t converted = 0;
    return ConvertWCharNToUtf8Alloc(title->string, title->length / sizeof(WCHAR), &converted);
}

static void set_visibility(vistara_remote_window *window, const RECTANGLE_16 *rects, UINT32 count) {
    free(window->visible_rects);
    window->visible_rects = NULL;
    window->visible_rect_count = 0;
    if (!rects || count == 0) {
        return;
    }
    window->visible_rects = calloc(count, sizeof(vistara_rect));
    if (!window->visible_rects) {
        return;
    }
    for (UINT32 index = 0; index < count; index++) {
        window->visible_rects[index] = (vistara_rect){
            .x = rects[index].left,
            .y = rects[index].top,
            .width = rects[index].right - rects[index].left,
            .height = rects[index].bottom - rects[index].top,
        };
    }
    window->visible_rect_count = count;
}

/// Applies the fields an order carries: an order that changes only the title
/// leaves the rest as it was. Locked.
static void apply_state(vistara_remote_app *app, uint32_t id, UINT32 flags, const WINDOW_STATE_ORDER *state) {
    window_entry *entry = entry_for(app, id, true);
    if (!entry) {
        return;
    }
    vistara_remote_window *window = &entry->window;
    if (flags & WINDOW_ORDER_STATE_NEW) {
        // A window id may be used again after its window was deleted.
        free_window_fields(window);
        memset(window, 0, sizeof(*window));
        window->id = id;
    }
    if (flags & WINDOW_ORDER_FIELD_OWNER) {
        window->owner_id = state->ownerWindowId;
    }
    if (flags & WINDOW_ORDER_FIELD_STYLE) {
        window->style = state->style;
        window->extended_style = state->extendedStyle;
    }
    if (flags & WINDOW_ORDER_FIELD_SHOW) {
        window->show_state = state->showState;
    }
    if (flags & WINDOW_ORDER_FIELD_TITLE) {
        free(window->title);
        window->title = title_from(&state->titleInfo);
    }
    if (flags & WINDOW_ORDER_FIELD_WND_OFFSET) {
        window->x = state->windowOffsetX;
        window->y = state->windowOffsetY;
    }
    if (flags & WINDOW_ORDER_FIELD_WND_SIZE) {
        window->width = state->windowWidth;
        window->height = state->windowHeight;
    }
    if (flags & WINDOW_ORDER_FIELD_VIS_OFFSET) {
        window->visible_x = state->visibleOffsetX;
        window->visible_y = state->visibleOffsetY;
    }
    if (flags & WINDOW_ORDER_FIELD_VISIBILITY) {
        set_visibility(window, state->visibilityRects, state->numVisibilityRects);
    }
    window->deleted = false;
    entry->changed = true;
}

/// Keeps a copy of an icon for a window if it is the largest so far. Locked.
static void apply_icon_image(vistara_remote_app *app, uint32_t id, const icon_image *icon) {
    window_entry *entry = entry_for(app, id, false);
    if (!entry || !icon->pixels) {
        return;
    }
    vistara_remote_window *window = &entry->window;
    if (window->icon_pixels && (uint64_t)window->icon_width * window->icon_height >
                                   (uint64_t)icon->width * icon->height) {
        return;
    }
    const size_t length = (size_t)icon->width * icon->height * 4;
    uint8_t *pixels = malloc(length);
    if (!pixels) {
        return;
    }
    memcpy(pixels, icon->pixels, length);
    free(window->icon_pixels);
    window->icon_pixels = pixels;
    window->icon_width = icon->width;
    window->icon_height = icon->height;
    entry->changed = true;
}

static void delete_window(vistara_remote_app *app, uint32_t id) {
    window_entry *entry = entry_for(app, id, false);
    if (entry) {
        entry->window.deleted = true;
        entry->changed = true;
    }
}

/// A deep copy of `window` into `copy`, or false.
static bool copy_window(const vistara_remote_window *window, vistara_remote_window *copy) {
    *copy = *window;
    copy->title = NULL;
    copy->visible_rects = NULL;
    copy->icon_pixels = NULL;
    if (window->title && !(copy->title = strdup(window->title))) {
        return false;
    }
    if (window->visible_rect_count > 0) {
        copy->visible_rects = calloc(window->visible_rect_count, sizeof(vistara_rect));
        if (!copy->visible_rects) {
            return false;
        }
        memcpy(copy->visible_rects, window->visible_rects, window->visible_rect_count * sizeof(vistara_rect));
    }
    if (window->icon_pixels) {
        const size_t length = (size_t)window->icon_width * window->icon_height * 4;
        if (!(copy->icon_pixels = malloc(length))) {
            return false;
        }
        memcpy(copy->icon_pixels, window->icon_pixels, length);
    }
    return true;
}

bool vistara_remote_app_take_windows(vistara_remote_app *app, vistara_remote_window **windows, size_t *count) {
    *windows = NULL;
    *count = 0;
    pthread_mutex_lock(&app->lock);
    size_t changed = 0;
    for (size_t index = 0; index < app->window_count; index++) {
        changed += app->windows[index].changed ? 1 : 0;
    }
    vistara_remote_window *list = changed ? calloc(changed, sizeof(*list)) : NULL;
    if (changed && !list) {
        pthread_mutex_unlock(&app->lock);
        return false;
    }
    size_t taken = 0;
    for (size_t index = 0; index < app->window_count; index++) {
        window_entry *entry = &app->windows[index];
        if (!entry->changed) {
            continue;
        }
        if (!copy_window(&entry->window, &list[taken])) {
            vistara_remote_windows_free(list, taken + 1);
            pthread_mutex_unlock(&app->lock);
            return false;
        }
        taken++;
        entry->changed = false;
    }
    // A deleted window is told once, then forgotten.
    size_t kept = 0;
    for (size_t index = 0; index < app->window_count; index++) {
        if (app->windows[index].window.deleted) {
            free_window_fields(&app->windows[index].window);
        } else {
            app->windows[kept++] = app->windows[index];
        }
    }
    app->window_count = kept;
    pthread_mutex_unlock(&app->lock);
    *windows = list;
    *count = taken;
    return taken > 0;
}

void vistara_remote_windows_free(vistara_remote_window *windows, size_t count) {
    if (!windows) {
        return;
    }
    for (size_t index = 0; index < count; index++) {
        free_window_fields(&windows[index]);
    }
    free(windows);
}

// MARK: Icons

/// An icon as the remote computer sends one, in any of Windows' formats,
/// as top-down BGRA; pixels NULL if it could not be read.
static icon_image icon_from(const ICON_INFO *info) {
    icon_image icon = {.width = info->width, .height = info->height, .pixels = NULL};
    if (info->width == 0 || info->height == 0 || info->width > VISTARA_ICON_MAX_SIDE ||
        info->height > VISTARA_ICON_MAX_SIDE || !info->bitsColor) {
        return icon;
    }
    const size_t stride = (size_t)info->width * 4;
    uint8_t *pixels = calloc(info->height, stride);
    if (!pixels) {
        return icon;
    }
    const BOOL converted = freerdp_image_copy_from_icon_data(
        pixels, PIXEL_FORMAT_BGRA32, (UINT32)stride, 0, 0, (UINT16)info->width, (UINT16)info->height,
        info->bitsColor, (UINT16)info->cbBitsColor, info->bitsMask, (UINT16)info->cbBitsMask, info->colorTable,
        (UINT16)info->cbColorTable, info->bpp);
    if (!converted) {
        free(pixels);
        return icon;
    }
    icon.pixels = pixels;
    return icon;
}

/// Keeps an icon where the remote computer may refer to it again. Locked;
/// takes ownership of a copy.
static void cache_icon(vistara_remote_app *app, const ICON_INFO *info, const icon_image *icon) {
    if (info->cacheEntry == VISTARA_ICON_NOT_CACHED || info->cacheId >= VISTARA_ICON_CACHES ||
        info->cacheEntry >= VISTARA_ICON_CACHE_ENTRIES || !icon->pixels) {
        return;
    }
    icon_image *slot = &app->icon_cache[info->cacheId][info->cacheEntry];
    const size_t length = (size_t)icon->width * icon->height * 4;
    uint8_t *pixels = malloc(length);
    if (!pixels) {
        return;
    }
    memcpy(pixels, icon->pixels, length);
    free(slot->pixels);
    *slot = (icon_image){.width = icon->width, .height = icon->height, .pixels = pixels};
}

// MARK: Window orders

static BOOL window_state(rdpContext *context, const WINDOW_ORDER_INFO *info, const WINDOW_STATE_ORDER *state) {
    vistara_remote_app *app = vistara_remote_app_for(context);
    if (!app || !info || !state) {
        return TRUE;
    }
    pthread_mutex_lock(&app->lock);
    apply_state(app, info->windowId, info->fieldFlags, state);
    pthread_mutex_unlock(&app->lock);
    return TRUE;
}

static BOOL window_delete(rdpContext *context, const WINDOW_ORDER_INFO *info) {
    vistara_remote_app *app = vistara_remote_app_for(context);
    if (!app || !info) {
        return TRUE;
    }
    pthread_mutex_lock(&app->lock);
    delete_window(app, info->windowId);
    pthread_mutex_unlock(&app->lock);
    return TRUE;
}

static BOOL window_icon(rdpContext *context, const WINDOW_ORDER_INFO *info, const WINDOW_ICON_ORDER *order) {
    vistara_remote_app *app = vistara_remote_app_for(context);
    if (!app || !info || !order || !order->iconInfo) {
        return TRUE;
    }
    icon_image icon = icon_from(order->iconInfo);
    pthread_mutex_lock(&app->lock);
    cache_icon(app, order->iconInfo, &icon);
    apply_icon_image(app, info->windowId, &icon);
    pthread_mutex_unlock(&app->lock);
    free(icon.pixels);
    return TRUE;
}

static BOOL window_cached_icon(rdpContext *context, const WINDOW_ORDER_INFO *info,
                               const WINDOW_CACHED_ICON_ORDER *order) {
    vistara_remote_app *app = vistara_remote_app_for(context);
    if (!app || !info || !order || order->cachedIcon.cacheId >= VISTARA_ICON_CACHES ||
        order->cachedIcon.cacheEntry >= VISTARA_ICON_CACHE_ENTRIES) {
        return TRUE;
    }
    pthread_mutex_lock(&app->lock);
    const icon_image icon = app->icon_cache[order->cachedIcon.cacheId][order->cachedIcon.cacheEntry];
    apply_icon_image(app, info->windowId, &icon);
    pthread_mutex_unlock(&app->lock);
    return TRUE;
}

/// Starts the program once both the desktop and the channel are ready, as
/// FreeRDP's own clients do. Locked on entry; unlocks to call the channel.
static void start_if_ready(vistara_remote_app *app) {
    RailClientContext *rail = app->rail;
    const bool start = app->desktop_ready && rail && !app->started;
    if (start) {
        app->started = true;
    }
    pthread_mutex_unlock(&app->lock);
    if (start) {
        // Client status, system parameters, and the program, from the settings.
        (void)client_rail_server_start_cmd(rail);
    }
}

static BOOL monitored_desktop(rdpContext *context, const WINDOW_ORDER_INFO *info,
                              const MONITORED_DESKTOP_ORDER *order) {
    (void)order;
    vistara_remote_app *app = vistara_remote_app_for(context);
    if (!app || !info) {
        return TRUE;
    }
    pthread_mutex_lock(&app->lock);
    if (info->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) {
        app->desktop_ready = true;
    }
    start_if_ready(app);
    return TRUE;
}

static BOOL non_monitored_desktop(rdpContext *context, const WINDOW_ORDER_INFO *info) {
    (void)context, (void)info;
    return TRUE;
}

void vistara_remote_app_register(rdpContext *context) {
    rdpWindowUpdate *window = context->update->window;
    window->WindowCreate = window_state;
    window->WindowUpdate = window_state;
    window->WindowDelete = window_delete;
    window->WindowIcon = window_icon;
    window->WindowCachedIcon = window_cached_icon;
    window->MonitoredDesktop = monitored_desktop;
    window->NonMonitoredDesktop = non_monitored_desktop;
}

// MARK: The RAIL channel

static void add_event(vistara_remote_app *app, vistara_remote_app_event event) {
    pthread_mutex_lock(&app->lock);
    if (app->event_count == app->event_capacity) {
        const size_t capacity = app->event_capacity ? app->event_capacity * 2 : 8;
        vistara_remote_app_event *grown = realloc(app->events, capacity * sizeof(*grown));
        if (!grown) {
            pthread_mutex_unlock(&app->lock);
            return;
        }
        app->events = grown;
        app->event_capacity = capacity;
    }
    app->events[app->event_count++] = event;
    void (*wake)(void *) = app->wake;
    void *wake_context = app->wake_context;
    pthread_mutex_unlock(&app->lock);
    if (wake) {
        wake(wake_context);
    }
}

static UINT execute_result(RailClientContext *rail, const RAIL_EXEC_RESULT_ORDER *result) {
    add_event(rail->custom, (vistara_remote_app_event){
                                .kind = VISTARA_REMOTE_APP_STARTED,
                                .code = result->execResult,
                            });
    return CHANNEL_RC_OK;
}

static UINT local_move_size(RailClientContext *rail, const RAIL_LOCALMOVESIZE_ORDER *order) {
    add_event(rail->custom, (vistara_remote_app_event){
                                .kind = order->isMoveSizeStart ? VISTARA_REMOTE_APP_MOVE_SIZE_BEGAN
                                                               : VISTARA_REMOTE_APP_MOVE_SIZE_ENDED,
                                .window_id = order->windowId,
                                .code = order->moveSizeType,
                                .x = order->posX,
                                .y = order->posY,
                            });
    return CHANNEL_RC_OK;
}

static UINT min_max_info(RailClientContext *rail, const RAIL_MINMAXINFO_ORDER *order) {
    add_event(rail->custom, (vistara_remote_app_event){
                                .kind = VISTARA_REMOTE_APP_SIZE_LIMITS,
                                .window_id = order->windowId,
                                .x = order->maxPosX,
                                .y = order->maxPosY,
                                .width = order->maxWidth,
                                .height = order->maxHeight,
                                .min_width = order->minTrackWidth,
                                .min_height = order->minTrackHeight,
                                .max_width = order->maxTrackWidth,
                                .max_height = order->maxTrackHeight,
                            });
    return CHANNEL_RC_OK;
}

static UINT server_system_param(RailClientContext *rail, const RAIL_SYSPARAM_ORDER *sysparam) {
    (void)rail, (void)sysparam;
    return CHANNEL_RC_OK;
}

void vistara_remote_app_channel_connected(vistara_remote_app *app, RailClientContext *rail,
                                          void (*wake)(void *), void *wake_context) {
    // The handshake keeps FreeRDP's own answer.
    rail->custom = app;
    rail->ServerExecuteResult = execute_result;
    rail->ServerLocalMoveSize = local_move_size;
    rail->ServerMinMaxInfo = min_max_info;
    rail->ServerSystemParam = server_system_param;
    pthread_mutex_lock(&app->lock);
    app->rail = rail;
    app->wake = wake;
    app->wake_context = wake_context;
    start_if_ready(app);
}

void vistara_remote_app_channel_disconnected(vistara_remote_app *app) {
    pthread_mutex_lock(&app->lock);
    app->rail = NULL;
    pthread_mutex_unlock(&app->lock);
}

bool vistara_remote_app_take_events(vistara_remote_app *app, vistara_remote_app_event **events, size_t *count) {
    pthread_mutex_lock(&app->lock);
    *events = app->events;
    *count = app->event_count;
    app->events = NULL;
    app->event_count = 0;
    app->event_capacity = 0;
    pthread_mutex_unlock(&app->lock);
    return *count > 0;
}

/// The channel, once the program was started, for an order to send.
static RailClientContext *started_rail(vistara_remote_app *app) {
    pthread_mutex_lock(&app->lock);
    RailClientContext *rail = app->started ? app->rail : NULL;
    pthread_mutex_unlock(&app->lock);
    return rail;
}

bool vistara_remote_app_start_program(vistara_remote_app *app, const char *program, const char *arguments) {
    RailClientContext *rail = started_rail(app);
    if (!rail || !program) {
        return false;
    }
    const RAIL_EXEC_ORDER exec = {
        .RemoteApplicationProgram = program,
        .RemoteApplicationArguments = arguments,
    };
    return rail->ClientExecute(rail, &exec) == CHANNEL_RC_OK;
}

bool vistara_remote_app_activate(vistara_remote_app *app, uint32_t window_id, bool active) {
    RailClientContext *rail = started_rail(app);
    if (!rail) {
        return false;
    }
    const RAIL_ACTIVATE_ORDER order = {.windowId = window_id, .enabled = active};
    return rail->ClientActivate(rail, &order) == CHANNEL_RC_OK;
}

static INT16 clamp16(int64_t value) {
    return (INT16)(value < INT16_MIN ? INT16_MIN : value > INT16_MAX ? INT16_MAX : value);
}

bool vistara_remote_app_move(vistara_remote_app *app, uint32_t window_id, vistara_rect frame) {
    RailClientContext *rail = started_rail(app);
    if (!rail) {
        return false;
    }
    const RAIL_WINDOW_MOVE_ORDER order = {
        .windowId = window_id,
        .left = clamp16(frame.x),
        .top = clamp16(frame.y),
        .right = clamp16((int64_t)frame.x + frame.width),
        .bottom = clamp16((int64_t)frame.y + frame.height),
    };
    return rail->ClientWindowMove(rail, &order) == CHANNEL_RC_OK;
}

bool vistara_remote_app_command(vistara_remote_app *app, uint32_t window_id, uint16_t command) {
    RailClientContext *rail = started_rail(app);
    if (!rail) {
        return false;
    }
    const RAIL_SYSCOMMAND_ORDER order = {.windowId = window_id, .command = command};
    return rail->ClientSystemCommand(rail, &order) == CHANNEL_RC_OK;
}

bool vistara_remote_app_set_work_area(vistara_remote_app *app, vistara_rect area) {
    RailClientContext *rail = started_rail(app);
    if (!rail) {
        return false;
    }
    RAIL_SYSPARAM_ORDER sysparam = {0};
    sysparam.params = SPI_MASK_SET_WORK_AREA;
    sysparam.workArea = (RECTANGLE_16){
        .left = (UINT16)clamp16(area.x),
        .top = (UINT16)clamp16(area.y),
        .right = (UINT16)clamp16((int64_t)area.x + area.width),
        .bottom = (UINT16)clamp16((int64_t)area.y + area.height),
    };
    return rail->ClientSystemParam(rail, &sysparam) == CHANNEL_RC_OK;
}

// MARK: For tests

static UINT32 freerdp_fields(uint32_t fields) {
    UINT32 flags = WINDOW_ORDER_TYPE_WINDOW;
    if (fields & VISTARA_WINDOW_FIELD_OWNER) flags |= WINDOW_ORDER_FIELD_OWNER;
    if (fields & VISTARA_WINDOW_FIELD_STYLE) flags |= WINDOW_ORDER_FIELD_STYLE;
    if (fields & VISTARA_WINDOW_FIELD_SHOW) flags |= WINDOW_ORDER_FIELD_SHOW;
    if (fields & VISTARA_WINDOW_FIELD_TITLE) flags |= WINDOW_ORDER_FIELD_TITLE;
    if (fields & VISTARA_WINDOW_FIELD_OFFSET) flags |= WINDOW_ORDER_FIELD_WND_OFFSET;
    if (fields & VISTARA_WINDOW_FIELD_SIZE) flags |= WINDOW_ORDER_FIELD_WND_SIZE;
    if (fields & VISTARA_WINDOW_FIELD_VISIBLE_OFFSET) flags |= WINDOW_ORDER_FIELD_VIS_OFFSET;
    if (fields & VISTARA_WINDOW_FIELD_VISIBILITY) flags |= WINDOW_ORDER_FIELD_VISIBILITY;
    if (fields & VISTARA_WINDOW_FIELD_NEW) flags |= WINDOW_ORDER_STATE_NEW;
    return flags;
}

void vistara_remote_app_apply(vistara_remote_app *app, uint32_t window_id, uint32_t fields,
                              const vistara_remote_window *values) {
    WINDOW_STATE_ORDER state = {0};
    state.ownerWindowId = values->owner_id;
    state.style = values->style;
    state.extendedStyle = values->extended_style;
    state.showState = values->show_state;
    WCHAR *title = NULL;
    if (values->title) {
        size_t length = 0;
        title = ConvertUtf8ToWCharAlloc(values->title, &length);
        state.titleInfo = (RAIL_UNICODE_STRING){.length = (UINT16)(length * sizeof(WCHAR)), .string = title};
    }
    state.windowOffsetX = values->x;
    state.windowOffsetY = values->y;
    state.windowWidth = values->width;
    state.windowHeight = values->height;
    state.visibleOffsetX = values->visible_x;
    state.visibleOffsetY = values->visible_y;
    RECTANGLE_16 *rects = values->visible_rect_count ? calloc(values->visible_rect_count, sizeof(*rects)) : NULL;
    for (size_t index = 0; rects && index < values->visible_rect_count; index++) {
        const vistara_rect rect = values->visible_rects[index];
        rects[index] = (RECTANGLE_16){
            .left = (UINT16)rect.x,
            .top = (UINT16)rect.y,
            .right = (UINT16)(rect.x + rect.width),
            .bottom = (UINT16)(rect.y + rect.height),
        };
    }
    state.visibilityRects = rects;
    state.numVisibilityRects = rects ? (UINT32)values->visible_rect_count : 0;
    pthread_mutex_lock(&app->lock);
    apply_state(app, window_id, freerdp_fields(fields), &state);
    pthread_mutex_unlock(&app->lock);
    free(rects);
    free(title);
}

void vistara_remote_app_apply_icon(vistara_remote_app *app, uint32_t window_id, uint32_t width, uint32_t height,
                                   const uint8_t *pixels) {
    ICON_INFO info = {
        .cacheEntry = VISTARA_ICON_NOT_CACHED,
        .bpp = 32,
        .width = width,
        .height = height,
        .cbBitsColor = width * height * 4,
        .bitsColor = (BYTE *)pixels,
    };
    icon_image icon = icon_from(&info);
    pthread_mutex_lock(&app->lock);
    apply_icon_image(app, window_id, &icon);
    pthread_mutex_unlock(&app->lock);
    free(icon.pixels);
}

void vistara_remote_app_delete(vistara_remote_app *app, uint32_t window_id) {
    pthread_mutex_lock(&app->lock);
    delete_window(app, window_id);
    pthread_mutex_unlock(&app->lock);
}
