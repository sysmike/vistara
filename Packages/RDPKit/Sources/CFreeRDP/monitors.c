#include "monitors.h"

#include <string.h>

/// Millimetres, as if the desktop were shown at 96 points per inch: the size
/// Windows uses to choose its scale when none is given.
static uint32_t physical_size(uint32_t pixels, uint32_t scale_percent) {
    if (scale_percent < 100) scale_percent = 100;
    return (uint32_t)((uint64_t)pixels * 2540 / ((uint64_t)96 * scale_percent));
}

static uint32_t clamped_scale(uint32_t scale_percent) {
    if (scale_percent < 100) return 100;
    if (scale_percent > 500) return 500;
    return scale_percent;
}

bool vistara_apply_monitors(rdpSettings *settings, const vistara_monitor *monitors, size_t count) {
    if (!monitors || count < 2) {
        return true;
    }
    if (count > VISTARA_MAX_MONITORS) count = VISTARA_MAX_MONITORS;

    rdpMonitor defined[VISTARA_MAX_MONITORS];
    memset(defined, 0, sizeof(defined));
    int64_t left = 0, top = 0, right = 0, bottom = 0;
    for (size_t index = 0; index < count; index++) {
        const vistara_monitor *monitor = &monitors[index];
        const uint32_t scale = clamped_scale(monitor->scale_percent);
        defined[index].x = monitor->x;
        defined[index].y = monitor->y;
        defined[index].width = (INT32)monitor->width;
        defined[index].height = (INT32)monitor->height;
        defined[index].is_primary = monitor->is_primary;
        defined[index].attributes.physicalWidth = physical_size(monitor->width, scale);
        defined[index].attributes.physicalHeight = physical_size(monitor->height, scale);
        defined[index].attributes.orientation = ORIENTATION_LANDSCAPE;
        defined[index].attributes.desktopScaleFactor = scale;
        defined[index].attributes.deviceScaleFactor = 100;
        if (index == 0 || monitor->x < left) left = monitor->x;
        if (index == 0 || monitor->y < top) top = monitor->y;
        if (index == 0 || monitor->x + (int64_t)monitor->width > right) right = monitor->x + (int64_t)monitor->width;
        if (index == 0 || monitor->y + (int64_t)monitor->height > bottom) bottom = monitor->y + (int64_t)monitor->height;
    }
    // The primary first, at the origin: FreeRDP checks and sorts.
    return freerdp_settings_set_monitor_def_array_sorted(settings, defined, count) &&
           freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SpanMonitors, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_HasMonitorAttributes, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportMonitorLayoutPdu, TRUE) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, (UINT32)(right - left)) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, (UINT32)(bottom - top));
}

size_t vistara_display_layout(const vistara_monitor *monitors, size_t count,
                              DISPLAY_CONTROL_MONITOR_LAYOUT layout[VISTARA_MAX_MONITORS]) {
    if (count > VISTARA_MAX_MONITORS) count = VISTARA_MAX_MONITORS;
    for (size_t index = 0; index < count; index++) {
        const vistara_monitor *monitor = &monitors[index];
        const uint32_t scale = clamped_scale(monitor->scale_percent);
        DISPLAY_CONTROL_MONITOR_LAYOUT *entry = &layout[index];
        memset(entry, 0, sizeof(*entry));
        entry->Flags = monitor->is_primary ? DISPLAY_CONTROL_MONITOR_PRIMARY : 0;
        entry->Left = monitor->x;
        entry->Top = monitor->y;
        entry->Width = monitor->width;
        entry->Height = monitor->height;
        entry->PhysicalWidth = physical_size(monitor->width, scale);
        entry->PhysicalHeight = physical_size(monitor->height, scale);
        entry->Orientation = ORIENTATION_LANDSCAPE;
        entry->DesktopScaleFactor = scale;
        entry->DeviceScaleFactor = 100;
    }
    return count;
}
