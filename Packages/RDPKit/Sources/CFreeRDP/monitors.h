#ifndef VISTARA_MONITORS_H
#define VISTARA_MONITORS_H

// Several monitors: the client monitor data sent when connecting, and the
// layout Display Control sends while connected. Positions are in remote
// pixels relative to the primary monitor, which is at the origin; the desktop
// is the monitors' bounding box.

#include "CFreeRDP.h"

#include <freerdp/channels/disp.h>
#include <freerdp/settings.h>

/// Sets the monitors to announce when connecting, and the desktop to their
/// bounding box. Does nothing for fewer than two monitors.
bool vistara_apply_monitors(rdpSettings *settings, const vistara_monitor *_Nullable monitors, size_t count);

/// Fills `layout` with at most VISTARA_MAX_MONITORS monitors for Display
/// Control and returns how many.
size_t vistara_display_layout(const vistara_monitor *monitors, size_t count,
                              DISPLAY_CONTROL_MONITOR_LAYOUT layout[VISTARA_MAX_MONITORS]);

#endif
