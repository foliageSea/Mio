#include "AtomicAudio.h"

#include <CoreAudio/CoreAudioTypes.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    _Atomic float gain;
} AMGainState;

void *AMGainStateCreate(float initialGain) {
    AMGainState *state = calloc(1, sizeof(AMGainState));
    if (state != NULL) {
        atomic_init(&state->gain, initialGain);
    }
    return state;
}

void AMGainStateDestroy(void *rawState) {
    free(rawState);
}

void AMGainStateSet(void *rawState, float gain) {
    AMGainState *state = rawState;
    if (state != NULL) {
        atomic_store_explicit(&state->gain, gain, memory_order_relaxed);
    }
}

bool AMAudioFormatIsSupported(const AudioStreamBasicDescription *format) {
    if (format == NULL || format->mFormatID != kAudioFormatLinearPCM) {
        return false;
    }

    const bool isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isSignedInteger = (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    if (isFloat) {
        return format->mBitsPerChannel == 32 || format->mBitsPerChannel == 64;
    }
    if (isSignedInteger) {
        return format->mBitsPerChannel == 16 || format->mBitsPerChannel == 32;
    }
    return false;
}

static void processFloat32(const void *input, void *output, size_t byteCount, float gain) {
    const float *source = input;
    float *destination = output;
    const size_t count = byteCount / sizeof(float);
    for (size_t index = 0; index < count; index++) {
        destination[index] = source[index] * gain;
    }
}

static void processFloat64(const void *input, void *output, size_t byteCount, float gain) {
    const double *source = input;
    double *destination = output;
    const size_t count = byteCount / sizeof(double);
    for (size_t index = 0; index < count; index++) {
        destination[index] = source[index] * gain;
    }
}

static void processInt16(const void *input, void *output, size_t byteCount, float gain) {
    const int16_t *source = input;
    int16_t *destination = output;
    const size_t count = byteCount / sizeof(int16_t);
    for (size_t index = 0; index < count; index++) {
        destination[index] = (int16_t)lrintf((float)source[index] * gain);
    }
}

static void processInt32(const void *input, void *output, size_t byteCount, float gain) {
    const int32_t *source = input;
    int32_t *destination = output;
    const size_t count = byteCount / sizeof(int32_t);
    for (size_t index = 0; index < count; index++) {
        destination[index] = (int32_t)llrint((double)source[index] * gain);
    }
}

void AMProcessAudio(
    const AudioBufferList *input,
    AudioBufferList *output,
    void *rawState,
    const AudioStreamBasicDescription *format
) {
    if (input == NULL || output == NULL || rawState == NULL || format == NULL) {
        return;
    }

    AMGainState *state = rawState;
    const float gain = atomic_load_explicit(&state->gain, memory_order_relaxed);

    for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
        AudioBuffer *buffer = &output->mBuffers[index];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }

    const UInt32 bufferCount = input->mNumberBuffers < output->mNumberBuffers
        ? input->mNumberBuffers
        : output->mNumberBuffers;
    const bool isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;

    for (UInt32 index = 0; index < bufferCount; index++) {
        const AudioBuffer *source = &input->mBuffers[index];
        AudioBuffer *destination = &output->mBuffers[index];
        if (source->mData == NULL || destination->mData == NULL) {
            continue;
        }

        const size_t byteCount = source->mDataByteSize < destination->mDataByteSize
            ? source->mDataByteSize
            : destination->mDataByteSize;

        if (isFloat && format->mBitsPerChannel == 32) {
            processFloat32(source->mData, destination->mData, byteCount, gain);
        } else if (isFloat && format->mBitsPerChannel == 64) {
            processFloat64(source->mData, destination->mData, byteCount, gain);
        } else if (format->mBitsPerChannel == 16) {
            processInt16(source->mData, destination->mData, byteCount, gain);
        } else if (format->mBitsPerChannel == 32) {
            processInt32(source->mData, destination->mData, byteCount, gain);
        }
    }
}
