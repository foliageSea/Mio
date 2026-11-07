#ifndef AtomicAudio_h
#define AtomicAudio_h

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>

void *AMGainStateCreate(float initialGain);
void AMGainStateDestroy(void *state);
void AMGainStateSet(void *state, float gain);

bool AMAudioFormatIsSupported(const AudioStreamBasicDescription *format);
void AMProcessAudio(
    const AudioBufferList *input,
    AudioBufferList *output,
    void *gainState,
    const AudioStreamBasicDescription *format
);

#endif
