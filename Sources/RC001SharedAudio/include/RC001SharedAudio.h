#ifndef RC001_SHARED_AUDIO_H
#define RC001_SHARED_AUDIO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RC001_AUDIO_OUTPUT_SAMPLE_RATE 48000u

typedef struct RC001AudioRingWriter RC001AudioRingWriter;
typedef struct RC001AudioRingReader RC001AudioRingReader;

/// Returns errno from the most recent failed shared-memory operation.
int RC001AudioRingLastError(void);

/// Creates or resets the cross-process ring buffer used by the bridge app.
RC001AudioRingWriter *RC001AudioRingWriterCreate(void);

/// Named variants are intended for isolated tests and diagnostics. Production
/// callers should use RC001AudioRingWriterCreate/RC001AudioRingReaderOpen.
RC001AudioRingWriter *RC001AudioRingWriterCreateNamed(const char *name);
void RC001AudioRingWriterDestroy(RC001AudioRingWriter *writer);

/// Marks the first sample of a new press-to-talk stream.
void RC001AudioRingWriterBeginStream(RC001AudioRingWriter *writer);

/// Writes mono signed PCM and converts 8/16 kHz remote audio to 48 kHz.
bool RC001AudioRingWriterWritePCM16(
    RC001AudioRingWriter *writer,
    const int16_t *samples,
    size_t sampleCount,
    uint32_t sourceSampleRate
);

/// Opens the ring from the Core Audio driver side. Returns NULL until the app has started.
RC001AudioRingReader *RC001AudioRingReaderOpen(void);
RC001AudioRingReader *RC001AudioRingReaderOpenNamed(const char *name);
void RC001AudioRingReaderClose(RC001AudioRingReader *reader);

/// Removes an isolated named ring after all of its test/diagnostic users close it.
bool RC001AudioRingUnlinkNamed(const char *name);

/// Fills an interleaved stereo Float32 Core Audio input buffer.
/// Mono remote audio is duplicated into both channels; underflow is filled with silence.
size_t RC001AudioRingReaderReadStereoFloat32(
    RC001AudioRingReader *reader,
    float *output,
    size_t frameCount
);

#ifdef __cplusplus
}
#endif

#endif
