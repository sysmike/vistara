#ifndef VISTARA_AUDIO_H
#define VISTARA_AUDIO_H

// The shim's sound output for FreeRDP's rdpsnd channel: plays what the remote
// computer sends through the Mac's current default output, and moves to a new
// default output when the user picks one.
//
// FreeRDP's own "mac" output stays on the device that was the default when the
// sound started, so it is not used.

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include <freerdp/client/rdpsnd.h>

/// The name the shim's output has among rdpsnd's outputs, as in "sys:vistara".
#define VISTARA_AUDIO_SUBSYSTEM "vistara"

/// What one session's sound output did, for tests and diagnostics. Written on
/// the channel's thread and the output's thread, read on any.
typedef struct {
    atomic_uint_fast64_t frames_received;
    atomic_uint_fast64_t frames_dropped;
    atomic_uint_fast32_t sample_rate;
    atomic_uint_fast32_t channels;
    atomic_uint_fast32_t outputs_opened;
    atomic_uint_fast32_t output_changes;
    atomic_bool output_running;
} vistara_audio_stats;

/// The rdpsnd output entry point that FreeRDP finds under VISTARA_AUDIO_SUBSYSTEM.
UINT VCAPITYPE vistara_rdpsnd_device_entry(PFREERDP_RDPSND_DEVICE_ENTRY_POINTS entry_points);

/// Where the session behind `context` keeps its sound counters. Implemented in
/// shim.c.
vistara_audio_stats *vistara_audio_stats_for(rdpContext *context);

#endif
