#include "audio.h"
#include "CFreeRDP.h"

#include <stdlib.h>
#include <string.h>

#include <freerdp/codec/audio.h>
#include <winpr/sysinfo.h>
#include <winpr/wlog.h>
#include <winpr/wtsapi.h>

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>

#define TAG "com.vistara.audio"

// CoreAudio and WinPR both define TRUE and FALSE, so this file returns the
// BOOLs FreeRDP expects as stdbool values, which are the same numbers.

/// The most sound that may wait for the output, in milliseconds. When the
/// output falls behind or does not run, newer sound is dropped, so the sound
/// never lags the picture by more than this.
#define VISTARA_AUDIO_MAX_QUEUED_MS 250

/// How often to look for a new default output, in milliseconds.
#define VISTARA_AUDIO_DEVICE_CHECK_MS 500

typedef struct {
    // First, because FreeRDP passes this struct as a rdpsndDevicePlugin.
    rdpsndDevicePlugin device;
    vistara_audio_stats *stats;
    // The format rdpsnd opened the output with: always 16-bit PCM here.
    AUDIO_FORMAT format;
    bool is_open;
    // The queue on the current default output, or NULL when there is none.
    AudioQueueRef queue;
    bool running;
    float volume;
    AudioObjectID output_device;
    uint_fast32_t pretended_changes;
    uint64_t last_device_check;
    // Bytes handed to the queue and not played yet. The queue's own thread
    // takes away what it played.
    atomic_uint_fast64_t queued_bytes;
    bool reported_failure;
} vistara_audio;

// For an output whose session cannot be found, so the counters always exist.
static vistara_audio_stats unused_stats;

// Raised by vistara_audio_pretend_output_changed(): every output then acts as
// if the user had picked another default output.
static atomic_uint_fast32_t pretended_changes;

void vistara_audio_pretend_output_changed(void) {
    atomic_fetch_add(&pretended_changes, 1);
}

static uint32_t bytes_per_frame(const vistara_audio *audio) {
    return 2u * audio->format.nChannels;
}

static uint32_t queued_ms(const vistara_audio *audio) {
    const uint64_t bytes_per_second = (uint64_t)audio->format.nSamplesPerSec * bytes_per_frame(audio);
    if (bytes_per_second == 0) {
        return 0;
    }
    const uint64_t ms = atomic_load(&audio->queued_bytes) * 1000 / bytes_per_second;
    return ms > UINT32_MAX ? UINT32_MAX : (uint32_t)ms;
}

static AudioObjectID default_output_device(void) {
    const AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
                                                kAudioObjectPropertyScopeGlobal,
                                                kAudioObjectPropertyElementMain};
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static void report_failure(vistara_audio *audio, const char *what, OSStatus status) {
    // Once per output: a Mac without a working output would say it for every packet.
    if (audio->reported_failure) {
        return;
    }
    audio->reported_failure = true;
    WLog_WARN(TAG, "%s failed (%d); the remote computer's sound is dropped", what, (int)status);
}

/// Called on the queue's thread once a buffer has been played.
static void buffer_played(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    vistara_audio *audio = context;
    const uint_fast64_t played = buffer->mAudioDataByteSize;
    uint_fast64_t queued = atomic_load(&audio->queued_bytes);
    while (!atomic_compare_exchange_weak(&audio->queued_bytes, &queued, queued > played ? queued - played : 0)) {
    }
    (void)AudioQueueFreeBuffer(queue, buffer);
}

static void close_output(vistara_audio *audio) {
    if (audio->queue) {
        // Both synchronous: no buffer_played() runs after this.
        (void)AudioQueueStop(audio->queue, true);
        (void)AudioQueueDispose(audio->queue, true);
        audio->queue = NULL;
    }
    audio->running = false;
    atomic_store(&audio->queued_bytes, 0);
    atomic_store(&audio->stats->output_running, false);
}

/// Makes a queue on the current default output, replacing any earlier one.
static void open_output(vistara_audio *audio) {
    close_output(audio);
    audio->output_device = default_output_device();
    audio->pretended_changes = atomic_load(&pretended_changes);
    audio->last_device_check = GetTickCount64();

    const UInt32 frame_bytes = bytes_per_frame(audio);
    const AudioStreamBasicDescription description = {
        .mSampleRate = audio->format.nSamplesPerSec,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        .mBytesPerPacket = frame_bytes,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = frame_bytes,
        .mChannelsPerFrame = audio->format.nChannels,
        .mBitsPerChannel = 16,
    };
    // No device is named, so the queue plays on the default output. A NULL
    // run loop runs buffer_played() on the queue's own thread.
    const OSStatus status = AudioQueueNewOutput(&description, buffer_played, audio, NULL, NULL, 0, &audio->queue);
    if (status != noErr) {
        audio->queue = NULL;
        report_failure(audio, "AudioQueueNewOutput", status);
        return;
    }
    (void)AudioQueueSetParameter(audio->queue, kAudioQueueParam_Volume, audio->volume);
    atomic_fetch_add(&audio->stats->outputs_opened, 1);
}

/// Moves to the default output when the user picked another one, for example
/// headphones. Looks at most every VISTARA_AUDIO_DEVICE_CHECK_MS.
static void follow_default_output(vistara_audio *audio) {
    const uint64_t now = GetTickCount64();
    if (now - audio->last_device_check < VISTARA_AUDIO_DEVICE_CHECK_MS) {
        return;
    }
    audio->last_device_check = now;
    if (default_output_device() == audio->output_device &&
        atomic_load(&pretended_changes) == audio->pretended_changes) {
        return;
    }
    WLog_INFO(TAG, "the default output changed; the sound moves to it");
    atomic_fetch_add(&audio->stats->output_changes, 1);
    audio->reported_failure = false;
    open_output(audio);
}

static BOOL audio_format_supported(rdpsndDevicePlugin *device, const AUDIO_FORMAT *format) {
    (void)device;
    // Other formats are decoded to 16-bit PCM by FreeRDP before they get here.
    return format->wFormatTag == WAVE_FORMAT_PCM && format->wBitsPerSample == 16 &&
           (format->nChannels == 1 || format->nChannels == 2) && format->nSamplesPerSec >= 8000 &&
           format->nSamplesPerSec <= 192000;
}

static BOOL audio_open(rdpsndDevicePlugin *device, const AUDIO_FORMAT *format, UINT32 latency) {
    (void)latency;
    vistara_audio *audio = (vistara_audio *)device;
    if (audio->is_open) {
        return true;
    }
    audio->format = *format;
    audio->format.data = NULL;
    audio->format.cbSize = 0;
    audio->is_open = true;
    audio->reported_failure = false;
    atomic_store(&audio->stats->sample_rate, format->nSamplesPerSec);
    atomic_store(&audio->stats->channels, format->nChannels);
    // An output that cannot be made costs only the sound, so this never
    // fails: failing would end the channel and the sound for the session.
    if (format->wBitsPerSample == 16 && format->nChannels >= 1 && format->nChannels <= 8 &&
        format->nSamplesPerSec > 0) {
        open_output(audio);
    }
    return true;
}

static UINT audio_play(rdpsndDevicePlugin *device, const BYTE *data, size_t size) {
    vistara_audio *audio = (vistara_audio *)device;
    const uint32_t frame_bytes = bytes_per_frame(audio);
    if (!audio->is_open || frame_bytes == 0 || size == 0 || size > UINT32_MAX) {
        return 0;
    }
    const uint64_t frames = size / frame_bytes;
    atomic_fetch_add(&audio->stats->frames_received, frames);
    follow_default_output(audio);

    const uint64_t duration_ms = frames * 1000 / audio->format.nSamplesPerSec;
    if (!audio->queue || queued_ms(audio) + duration_ms > VISTARA_AUDIO_MAX_QUEUED_MS) {
        atomic_fetch_add(&audio->stats->frames_dropped, frames);
        return queued_ms(audio);
    }

    AudioQueueBufferRef buffer = NULL;
    OSStatus status = AudioQueueAllocateBuffer(audio->queue, (UInt32)size, &buffer);
    if (status != noErr) {
        report_failure(audio, "AudioQueueAllocateBuffer", status);
        atomic_fetch_add(&audio->stats->frames_dropped, frames);
        return queued_ms(audio);
    }
    memcpy(buffer->mAudioData, data, size);
    buffer->mAudioDataByteSize = (UInt32)size;
    atomic_fetch_add(&audio->queued_bytes, size);
    status = AudioQueueEnqueueBuffer(audio->queue, buffer, 0, NULL);
    if (status != noErr) {
        atomic_fetch_sub(&audio->queued_bytes, size);
        (void)AudioQueueFreeBuffer(audio->queue, buffer);
        report_failure(audio, "AudioQueueEnqueueBuffer", status);
        atomic_fetch_add(&audio->stats->frames_dropped, frames);
        return queued_ms(audio);
    }

    // Tried again with every packet until it works, so sound starts as soon
    // as an output appears.
    if (!audio->running) {
        status = AudioQueueStart(audio->queue, NULL);
        if (status == noErr) {
            audio->running = true;
            atomic_store(&audio->stats->output_running, true);
        } else {
            report_failure(audio, "AudioQueueStart", status);
        }
    }
    // What still waits to be heard: rdpsnd reports it to the server, which
    // keeps the picture and the sound together with it.
    return queued_ms(audio);
}

static BOOL audio_set_volume(rdpsndDevicePlugin *device, UINT32 value) {
    vistara_audio *audio = (vistara_audio *)device;
    const uint32_t left = value & 0xFFFF;
    const uint32_t right = (value >> 16) & 0xFFFF;
    audio->volume = (float)(left + right) / (2.0f * 65535.0f);
    if (audio->queue) {
        (void)AudioQueueSetParameter(audio->queue, kAudioQueueParam_Volume, audio->volume);
    }
    return true;
}

static void audio_close(rdpsndDevicePlugin *device) {
    vistara_audio *audio = (vistara_audio *)device;
    close_output(audio);
    audio->is_open = false;
}

static void audio_free(rdpsndDevicePlugin *device) {
    audio_close(device);
    free(device);
}

UINT VCAPITYPE vistara_rdpsnd_device_entry(PFREERDP_RDPSND_DEVICE_ENTRY_POINTS entry_points) {
    vistara_audio *audio = calloc(1, sizeof(*audio));
    if (!audio) {
        return CHANNEL_RC_NO_MEMORY;
    }
    vistara_audio_stats *stats = vistara_audio_stats_for(freerdp_rdpsnd_get_context(entry_points->rdpsnd));
    audio->stats = stats ? stats : &unused_stats;
    audio->volume = 1.0f;
    audio->device.FormatSupported = audio_format_supported;
    audio->device.Open = audio_open;
    audio->device.SetVolume = audio_set_volume;
    audio->device.Play = audio_play;
    audio->device.Close = audio_close;
    audio->device.Free = audio_free;
    entry_points->pRegisterRdpsndDevice(entry_points->rdpsnd, &audio->device);
    return CHANNEL_RC_OK;
}
