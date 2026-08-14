#include "RC001SharedAudio.h"

#include <fcntl.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define RC001_AUDIO_SHM_NAME "/RC001MacBridgeAudio-v1"
#define RC001_AUDIO_MAGIC 0x52433031u
#define RC001_AUDIO_VERSION 1u
#define RC001_AUDIO_CAPACITY (RC001_AUDIO_OUTPUT_SAMPLE_RATE * 10u)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t capacity;
    _Atomic uint64_t generation;
    _Atomic uint64_t streamStartIndex;
    _Atomic uint64_t writeIndex;
    int16_t samples[RC001_AUDIO_CAPACITY];
} RC001AudioSharedMemory;

struct RC001AudioRingWriter {
    int descriptor;
    RC001AudioSharedMemory *memory;
};

struct RC001AudioRingReader {
    int descriptor;
    const RC001AudioSharedMemory *memory;
    uint64_t generation;
    uint64_t readIndex;
};

static _Atomic int gRC001AudioRingLastError = 0;

int RC001AudioRingLastError(void) {
    return atomic_load_explicit(&gRC001AudioRingLastError, memory_order_relaxed);
}

static void RC001AudioRingRememberError(int stage) {
    atomic_store_explicit(&gRC001AudioRingLastError, stage * 1000 + errno, memory_order_relaxed);
}

static bool RC001AudioMemoryIsValid(const RC001AudioSharedMemory *memory) {
    return memory != NULL
        && memory->magic == RC001_AUDIO_MAGIC
        && memory->version == RC001_AUDIO_VERSION
        && memory->sampleRate == RC001_AUDIO_OUTPUT_SAMPLE_RATE
        && memory->capacity == RC001_AUDIO_CAPACITY;
}

RC001AudioRingWriter *RC001AudioRingWriterCreate(void) {
    return RC001AudioRingWriterCreateNamed(RC001_AUDIO_SHM_NAME);
}

RC001AudioRingWriter *RC001AudioRingWriterCreateNamed(const char *name) {
    if (name == NULL || name[0] == '\0') {
        errno = EINVAL;
        RC001AudioRingRememberError(1);
        return NULL;
    }

    int descriptor = shm_open(name, O_CREAT | O_RDWR, 0666);
    if (descriptor < 0) {
        RC001AudioRingRememberError(1);
        return NULL;
    }

    struct stat objectStatus;
    if (fstat(descriptor, &objectStatus) != 0) {
        RC001AudioRingRememberError(2);
        close(descriptor);
        return NULL;
    }
    bool resized = objectStatus.st_size < (off_t)sizeof(RC001AudioSharedMemory);
    if (resized) {
        // Darwin reports a POSIX shared-memory object's size rounded up to a
        // page boundary. Treating any non-exact size as incompatible unlinked
        // the live object and split existing readers from a newly created
        // writer. Grow undersized objects in place and accept larger ones.
        if (ftruncate(descriptor, (off_t)sizeof(RC001AudioSharedMemory)) != 0) {
            RC001AudioRingRememberError(2);
            close(descriptor);
            return NULL;
        }
    }

    RC001AudioSharedMemory *memory = mmap(
        NULL,
        sizeof(RC001AudioSharedMemory),
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptor,
        0
    );
    if (memory == MAP_FAILED) {
        RC001AudioRingRememberError(3);
        close(descriptor);
        return NULL;
    }

    bool reusable = !resized && RC001AudioMemoryIsValid(memory);
    if (reusable) {
        // Keep the generation monotonic across app restarts so a reader that
        // remains open can discard its old cursor and follow the new writer.
        uint64_t nextGeneration = atomic_load_explicit(
            &memory->generation,
            memory_order_acquire
        ) + 1;
        atomic_store_explicit(&memory->streamStartIndex, 0, memory_order_relaxed);
        atomic_store_explicit(&memory->writeIndex, 0, memory_order_relaxed);
        atomic_store_explicit(&memory->generation, nextGeneration, memory_order_release);
    } else {
        memset(memory, 0, sizeof(*memory));
        memory->magic = RC001_AUDIO_MAGIC;
        memory->version = RC001_AUDIO_VERSION;
        memory->sampleRate = RC001_AUDIO_OUTPUT_SAMPLE_RATE;
        memory->capacity = RC001_AUDIO_CAPACITY;
        atomic_store_explicit(&memory->generation, 0, memory_order_relaxed);
        atomic_store_explicit(&memory->streamStartIndex, 0, memory_order_relaxed);
        atomic_store_explicit(&memory->writeIndex, 0, memory_order_release);
    }

    RC001AudioRingWriter *writer = calloc(1, sizeof(*writer));
    if (writer == NULL) {
        munmap(memory, sizeof(*memory));
        close(descriptor);
        return NULL;
    }
    writer->descriptor = descriptor;
    writer->memory = memory;
    return writer;
}

void RC001AudioRingWriterDestroy(RC001AudioRingWriter *writer) {
    if (writer == NULL) {
        return;
    }
    if (writer->memory != NULL) {
        munmap(writer->memory, sizeof(*writer->memory));
    }
    if (writer->descriptor >= 0) {
        close(writer->descriptor);
    }
    free(writer);
}

void RC001AudioRingWriterBeginStream(RC001AudioRingWriter *writer) {
    if (writer == NULL || !RC001AudioMemoryIsValid(writer->memory)) {
        return;
    }

    uint64_t writeIndex = atomic_load_explicit(&writer->memory->writeIndex, memory_order_acquire);
    atomic_store_explicit(&writer->memory->streamStartIndex, writeIndex, memory_order_release);
    atomic_fetch_add_explicit(&writer->memory->generation, 1, memory_order_acq_rel);
}

bool RC001AudioRingWriterWritePCM16(
    RC001AudioRingWriter *writer,
    const int16_t *samples,
    size_t sampleCount,
    uint32_t sourceSampleRate
) {
    if (writer == NULL || samples == NULL || !RC001AudioMemoryIsValid(writer->memory)) {
        return false;
    }
    if (sourceSampleRate == 0 || RC001_AUDIO_OUTPUT_SAMPLE_RATE % sourceSampleRate != 0) {
        return false;
    }

    uint32_t expansion = RC001_AUDIO_OUTPUT_SAMPLE_RATE / sourceSampleRate;
    if (expansion == 0 || expansion > 12) {
        return false;
    }

    uint64_t writeIndex = atomic_load_explicit(&writer->memory->writeIndex, memory_order_relaxed);
    for (size_t sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
        for (uint32_t copyIndex = 0; copyIndex < expansion; ++copyIndex) {
            writer->memory->samples[writeIndex % RC001_AUDIO_CAPACITY] = samples[sampleIndex];
            writeIndex += 1;
        }
    }
    atomic_store_explicit(&writer->memory->writeIndex, writeIndex, memory_order_release);
    return true;
}

RC001AudioRingReader *RC001AudioRingReaderOpen(void) {
    return RC001AudioRingReaderOpenNamed(RC001_AUDIO_SHM_NAME);
}

RC001AudioRingReader *RC001AudioRingReaderOpenNamed(const char *name) {
    if (name == NULL || name[0] == '\0') {
        errno = EINVAL;
        RC001AudioRingRememberError(4);
        return NULL;
    }

    int descriptor = shm_open(name, O_RDONLY, 0);
    if (descriptor < 0) {
        RC001AudioRingRememberError(4);
        return NULL;
    }

    const RC001AudioSharedMemory *memory = mmap(
        NULL,
        sizeof(RC001AudioSharedMemory),
        PROT_READ,
        MAP_SHARED,
        descriptor,
        0
    );
    if (memory == MAP_FAILED || !RC001AudioMemoryIsValid(memory)) {
        if (memory == MAP_FAILED) {
            RC001AudioRingRememberError(5);
        }
        if (memory != MAP_FAILED) {
            munmap((void *)memory, sizeof(*memory));
        }
        close(descriptor);
        return NULL;
    }

    RC001AudioRingReader *reader = calloc(1, sizeof(*reader));
    if (reader == NULL) {
        munmap((void *)memory, sizeof(*memory));
        close(descriptor);
        return NULL;
    }

    reader->descriptor = descriptor;
    reader->memory = memory;
    reader->generation = atomic_load_explicit(&memory->generation, memory_order_acquire);
    reader->readIndex = atomic_load_explicit(&memory->streamStartIndex, memory_order_acquire);
    return reader;
}

void RC001AudioRingReaderClose(RC001AudioRingReader *reader) {
    if (reader == NULL) {
        return;
    }
    if (reader->memory != NULL) {
        munmap((void *)reader->memory, sizeof(*reader->memory));
    }
    if (reader->descriptor >= 0) {
        close(reader->descriptor);
    }
    free(reader);
}

size_t RC001AudioRingReaderReadStereoFloat32(
    RC001AudioRingReader *reader,
    float *output,
    size_t frameCount
) {
    if (output == NULL) {
        return 0;
    }
    memset(output, 0, frameCount * 2 * sizeof(float));
    if (reader == NULL || !RC001AudioMemoryIsValid(reader->memory)) {
        return 0;
    }

    uint64_t generation = atomic_load_explicit(&reader->memory->generation, memory_order_acquire);
    if (generation != reader->generation) {
        reader->generation = generation;
        reader->readIndex = atomic_load_explicit(
            &reader->memory->streamStartIndex,
            memory_order_acquire
        );
    }

    uint64_t writeIndex = atomic_load_explicit(&reader->memory->writeIndex, memory_order_acquire);
    if (writeIndex < reader->readIndex) {
        reader->readIndex = writeIndex;
    } else if (writeIndex - reader->readIndex > RC001_AUDIO_CAPACITY) {
        reader->readIndex = writeIndex - RC001_AUDIO_CAPACITY;
    }

    uint64_t available = writeIndex - reader->readIndex;
    size_t framesToRead = available < frameCount ? (size_t)available : frameCount;
    for (size_t frame = 0; frame < framesToRead; ++frame) {
        int16_t sample = reader->memory->samples[(reader->readIndex + frame) % RC001_AUDIO_CAPACITY];
        float normalized = (float)sample / 32768.0f;
        output[frame * 2] = normalized;
        output[frame * 2 + 1] = normalized;
    }
    reader->readIndex += framesToRead;
    return framesToRead;
}

bool RC001AudioRingUnlinkNamed(const char *name) {
    if (name == NULL || name[0] == '\0') {
        errno = EINVAL;
        RC001AudioRingRememberError(6);
        return false;
    }
    if (shm_unlink(name) == 0 || errno == ENOENT) {
        return true;
    }
    RC001AudioRingRememberError(6);
    return false;
}
