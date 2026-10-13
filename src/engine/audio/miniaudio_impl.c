/* The miniaudio C shim: the ONE translation unit that compiles miniaudio (M8).
 *
 * Why it exists: Zig 0.16's translate-c cannot lower the whole miniaudio header
 * (`@cImport` on it fails the same way it fails on `stb_image.h` — see
 * `src/engine/assets/stb_image_impl.c`), so miniaudio is compiled as C and the
 * Zig side (`backend_miniaudio.zig`) declares just the small surface below.
 * Everything engine-side stays Zig. What is C here is exactly what the port
 * says a backend owns: the device, its thread, its format handling, and
 * load-time decoding.
 *
 * Two rules this file obeys:
 *   - the data callback does NOT allocate, lock, or touch the filesystem: it
 *     calls the mixer that was handed to it and times it;
 *   - decoding happens at load time only, and the caller owns the returned
 *     buffer through `ember_audio_free` and nothing else.
 *
 * The vendored header is pinned in `libs/miniaudio.commit`, installed by
 * `libs/bootstrap.sh`, and found by the include path `build.zig` gives the
 * audio module.
 */

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdlib.h>
#include <string.h>

typedef void (*ember_audio_mix_fn)(void* pCtx, float* pOut, ma_uint32 frames);

typedef struct ember_audio
{
    ma_device device;
    ma_bool32 initialized;
    ember_audio_mix_fn mix;
    void* mix_ctx;
    ma_uint32 requested_rate;
    ma_uint32 rate;           /* the rate the data callback receives */
    ma_uint32 channels;       /* the channel count the data callback receives */
    ma_uint32 period_frames;  /* the period the device was asked to run */
    ma_uint32 callback_frames; /* frames the LAST callback was handed */
    ma_uint64 xruns;          /* mixes that ran past their period */
    ma_uint64 buffers;
} ember_audio;

static void ember_on_data(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount)
{
    ember_audio* a = (ember_audio*)pDevice->pUserData;
    (void)pInput;

    if (a == NULL) {
        return;
    }

    /* The callback size is MEASURED, not assumed: a backend is free to hand us
     * a bigger buffer than we asked for, and the port's latency is defined by
     * what the device actually asks for per callback. Written before the mix so
     * a mix that overruns still reports the period it overran. */
    a->callback_frames = frameCount;

    ma_timer timer;
    ma_timer_init(&timer);

    if (a->mix != NULL) {
        a->mix(a->mix_ctx, (float*)pOutput, frameCount);
    } else {
        memset(pOutput, 0, (size_t)frameCount * a->channels * sizeof(float));
    }

    /* The port's `xruns`, defined where only this file can see it: a mix that
     * did not finish inside the period the device asked for is the mix that
     * glitched. It is derived from the period rather than read from a driver
     * counter, and `backend_miniaudio.zig` says so in the stats doc. */
    if (a->rate > 0) {
        const double budget = (double)frameCount / (double)a->rate;
        if (ma_timer_get_time_in_seconds(&timer) > budget) {
            a->xruns += 1;
        }
    }
    a->buffers += 1;
}

ember_audio* ember_audio_open(ma_uint32 sample_rate, ma_uint32 period_frames, ma_uint32 channels,
                              ember_audio_mix_fn mix, void* pCtx)
{
    if (channels == 0) {
        channels = 2;
    }

    ember_audio* a = (ember_audio*)calloc(1, sizeof(ember_audio));
    if (a == NULL) {
        return NULL;
    }

    a->mix = mix;
    a->mix_ctx = pCtx;
    a->requested_rate = sample_rate;

    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format    = ma_format_f32;
    config.playback.channels  = channels;
    config.sampleRate         = sample_rate;
    config.periodSizeInFrames = period_frames;
    config.dataCallback       = ember_on_data;
    config.pUserData          = a;

    if (ma_device_init(NULL, &config, &a->device) != MA_SUCCESS) {
        /* The rate and the period are REQUESTS. A device that will not take
         * them is not a reason to go silent, so try once more at the device's
         * own rate — and report what was actually negotiated either way. */
        if (sample_rate == 0) {
            free(a);
            return NULL;
        }
        config.sampleRate = 0;
        if (ma_device_init(NULL, &config, &a->device) != MA_SUCCESS) {
            free(a);
            return NULL;
        }
    }

    a->initialized   = MA_TRUE;
    a->rate          = a->device.sampleRate;
    a->channels      = a->device.playback.channels;
    /* NOT `internalPeriodSizeInFrames`: on PulseAudio that is the whole server
     * buffer (three times the period), which would report 30 ms of "latency"
     * for a device that hands us 10 ms buffers. Until the first callback tells
     * us the truth, the requested period is the honest placeholder. */
    a->period_frames = period_frames ? period_frames : 480;

    /* Fall back to what was asked for whenever the device answers with a zero
     * (a backend that does not report a rate or a channel count): a zero here
     * would make `latencyMs()` read as 0 ms, which is a lie, not a measurement. */
    if (a->rate == 0)     a->rate     = sample_rate ? sample_rate : 48000;
    if (a->channels == 0) a->channels = channels;

    return a;
}

void ember_audio_close(ember_audio* a)
{
    if (a == NULL) {
        return;
    }
    if (a->initialized) {
        ma_device_uninit(&a->device);
        a->initialized = MA_FALSE;
    }
    free(a);
}

int ember_audio_start(ember_audio* a)
{
    if (a == NULL) {
        return 0;
    }
    return ma_device_start(&a->device) == MA_SUCCESS ? 1 : 0;
}

void ember_audio_stop(ember_audio* a)
{
    if (a != NULL) {
        ma_device_stop(&a->device);
    }
}

ma_uint32 ember_audio_rate(const ember_audio* a)         { return a != NULL ? a->rate : 0; }
ma_uint32 ember_audio_channels(const ember_audio* a)     { return a != NULL ? a->channels : 0; }
ma_uint32 ember_audio_period(const ember_audio* a)
{
    if (a == NULL) {
        return 0;
    }
    return a->callback_frames != 0 ? a->callback_frames : a->period_frames;
}
ma_uint64 ember_audio_xruns(const ember_audio* a)        { return a != NULL ? a->xruns : 0; }
ma_uint64 ember_audio_buffers(const ember_audio* a)      { return a != NULL ? a->buffers : 0; }

/* The backend that answered (alsa, pulseaudio, pipewire, coreaudio, ...), for
 * the boot log line. A static string owned by miniaudio: the caller may hold it
 * for the lifetime of the process, and never frees it. */
const char* ember_audio_backend(const ember_audio* a)
{
    if (a == NULL) {
        return "miniaudio";
    }
    ma_context* pContext = ma_device_get_context((ma_device*)&a->device);
    if (pContext == NULL) {
        return "miniaudio";
    }
    return ma_get_backend_name(pContext->backend);
}

/* Decode a file to interleaved f32 at its NATIVE rate and channel count: the
 * mixer is what resamples voices and folds channels, so nothing is decided here
 * that a 44.1 kHz mono asset would have to live with forever.
 *
 * Returns 0 on success; 1 = not found / could not open, 2 = unsupported format,
 * 3 = out of memory — the same three cases the port's `DecodeError` names. The
 * returned buffer belongs to the caller and MUST go through `ember_audio_free`.
 */
int ember_audio_decode(const char* path, float** out_samples, ma_uint64* out_frames,
                       ma_uint32* out_rate, ma_uint32* out_channels)
{
    ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 0, 0);
    ma_decoder decoder;

    if (path == NULL) {
        return 1;
    }
    ma_result init_result = ma_decoder_init_file(path, &config, &decoder);
    if (init_result != MA_SUCCESS) {
        /* "Not there" and "not a sound file" are different problems with
         * different fixes, so they stay different errors all the way up. */
        if (init_result == MA_DOES_NOT_EXIST || init_result == MA_IO_ERROR) {
            return 1;
        }
        return 2;
    }

    /* Asked for rate 0 and 0 channels, the decoder resolves both to the file's
     * own values and reports them back — which is exactly the "native" answer
     * the mixer wants, so no guessing is needed. */
    ma_uint32 rate = decoder.outputSampleRate;
    ma_uint32 channels = decoder.outputChannels;
    if (rate == 0) {
        rate = 48000;
    }
    if (channels == 0) {
        channels = 1;
    }

    /* The length is a HINT, not a fact: Vorbis reports nothing, MP3 reports the
     * compressed estimate, and the asset layer this replaces allocated for the
     * hint and read once — which silently truncated every longer file. So the
     * buffer grows while reading, and a known length merely starts it right. */
    ma_uint64 capacity = 0;
    if (ma_decoder_get_length_in_pcm_frames(&decoder, &capacity) != MA_SUCCESS || capacity == 0) {
        capacity = 4096;
    }
    capacity += 1;

    const size_t stride = (size_t)channels;
    float* buffer = (float*)malloc((size_t)capacity * stride * sizeof(float));
    if (buffer == NULL) {
        ma_decoder_uninit(&decoder);
        return 3;
    }

    ma_uint64 total = 0;
    for (;;) {
        if (total + 4096 > capacity) {
            ma_uint64 next = capacity * 2;
            float* grown = (float*)realloc(buffer, (size_t)next * stride * sizeof(float));
            if (grown == NULL) {
                free(buffer);
                ma_decoder_uninit(&decoder);
                return 3;
            }
            buffer = grown;
            capacity = next;
        }

        ma_uint64 want = capacity - total;
        if (want > 4096) {
            want = 4096;
        }

        ma_uint64 got = 0;
        ma_result result = ma_decoder_read_pcm_frames(&decoder, buffer + total * stride, want, &got);
        total += got;

        if (result == MA_AT_END || got == 0) {
            break;
        }
        if (result != MA_SUCCESS) {
            /* Exactly one free path per error, which is the bug the asset layer
             * it replaces had twice. */
            free(buffer);
            ma_decoder_uninit(&decoder);
            return 2;
        }
    }

    ma_decoder_uninit(&decoder);

    *out_samples  = buffer;
    *out_frames   = total;
    *out_rate     = rate;
    *out_channels = channels;
    return 0;
}

void ember_audio_free(void* p)
{
    if (p != NULL) {
        free(p);
    }
}

/* ── Streaming ────────────────────────────────────────────────────────────
 * A stream keeps the decoder OPEN and reads a chunk at a time, so a long file
 * never has to be resident all at once.
 *
 * Split by thread on purpose: `ember_audio_stream_open` does the filesystem
 * work and is called at LOAD time; `ember_audio_stream_read` is called by the
 * ENGINE'S MAIN THREAD into a ring it owns, never by the device callback,
 * which must not touch the disk (spec §3.4, §10). The device thread only ever
 * reads the ring, which is plain memory.
 *
 * `frames` = 0 in the info means the length is not known ahead of time (Vorbis,
 * a live source); the reader then has to go by end-of-read, which is why the
 * caller cannot assume a length it was not given.
 */
typedef struct ember_stream
{
    ma_decoder decoder;
    ma_uint32 channels;
} ember_stream;

typedef struct ember_stream_info
{
    ma_uint64 frames;
    ma_uint32 rate;
    ma_uint32 channels;
} ember_stream_info;

ember_stream* ember_audio_stream_open(const char* path, ember_stream_info* out)
{
    if (path == NULL) {
        return NULL;
    }
    ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 0, 0);
    ember_stream* s = (ember_stream*)calloc(1, sizeof(ember_stream));
    if (s == NULL) {
        return NULL;
    }
    if (ma_decoder_init_file(path, &config, &s->decoder) != MA_SUCCESS) {
        free(s);
        return NULL;
    }
    s->channels = s->decoder.outputChannels ? s->decoder.outputChannels : 1;
    ma_uint64 frames = 0;
    /* A hint, not a fact: a format that cannot report a length leaves it 0. */
    (void)ma_decoder_get_length_in_pcm_frames(&s->decoder, &frames);
    if (out != NULL) {
        out->frames = frames;
        out->rate = s->decoder.outputSampleRate ? s->decoder.outputSampleRate : 48000;
        out->channels = s->channels;
    }
    return s;
}

/* Reads up to `frames` frames of interleaved f32. Returns how many it produced;
 * 0 means end of source. Never allocates. */
ma_uint64 ember_audio_stream_read(ember_stream* s, float* out, ma_uint64 frames)
{
    if (s == NULL || out == NULL || frames == 0) {
        return 0;
    }
    ma_uint64 got = 0;
    (void)ma_decoder_read_pcm_frames(&s->decoder, out, frames, &got);
    return got;
}

int ember_audio_stream_seek(ember_stream* s, ma_uint64 frame)
{
    if (s == NULL) {
        return 0;
    }
    return ma_decoder_seek_to_pcm_frame(&s->decoder, frame) == MA_SUCCESS ? 1 : 0;
}

void ember_audio_stream_close(ember_stream* s)
{
    if (s == NULL) {
        return;
    }
    ma_decoder_uninit(&s->decoder);
    free(s);
}
