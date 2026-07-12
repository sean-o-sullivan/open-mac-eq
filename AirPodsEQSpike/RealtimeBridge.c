#include "RealtimeBridge.h"

#include <CoreAudio/HostTime.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    double z1;
    double z2;
} EQBiquadState;

typedef struct {
    EQBiquadCoefficients coefficients[EQRealtimeDSPMaximumBandCount];
    EQBiquadState states[EQRealtimeDSPMaximumChannelCount][EQRealtimeDSPMaximumBandCount];
    double preampLinear;
    uint32_t bandCount;
} EQDSPBank;

typedef struct {
    _Atomic uint64_t generation;
    _Atomic uint64_t coefficientBits[EQRealtimeDSPMaximumBandCount][5];
    _Atomic uint64_t preampBits;
    _Atomic uint32_t bandCount;
    _Atomic uint32_t crossfadeFrames;
} EQDSPMailbox;

struct EQRealtimeDSP {
    EQDSPMailbox mailbox;
    EQDSPBank banks[2];
    uint64_t lastAppliedGeneration;
    uint64_t fadingToGeneration;
    uint32_t activeBankIndex;
    uint32_t fadeTargetBankIndex;
    uint32_t crossfadeFramesTotal;
    uint32_t crossfadeFramesRemaining;
};

struct EQRealtimeStats {
    _Atomic uint64_t callbackCount;
    _Atomic uint64_t frameCount;
    _Atomic uint64_t formatMismatchCount;
    _Atomic uint64_t dspConfigurationApplyCount;
    _Atomic uint64_t nonFiniteOutputCount;
    _Atomic uint64_t processorOverloadCount;
    _Atomic uint64_t lastTimestampDeltaNanos;
    _Atomic uint64_t lastProcessingNanos;
    _Atomic uint64_t maximumProcessingNanos;
    _Atomic uint32_t lastInputBufferCount;
    _Atomic uint32_t lastOutputBufferCount;
    _Atomic uint32_t lastFrameCount;
    _Atomic uint32_t activeBandCount;
    _Atomic uint32_t crossfadeFramesRemaining;
};

static uint64_t EQDoubleBits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double EQDoubleFromBits(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static bool EQCoefficientsAreValid(EQBiquadCoefficients c) {
    return isfinite(c.b0) && isfinite(c.b1) && isfinite(c.b2) &&
        isfinite(c.a1) && isfinite(c.a2) && fabs(c.a2) < 1.0 &&
        1.0 + c.a1 + c.a2 > 0.0 && 1.0 - c.a1 + c.a2 > 0.0;
}

EQRealtimeStats *EQRealtimeStatsCreate(void) {
    return calloc(1, sizeof(EQRealtimeStats));
}

void EQRealtimeStatsDestroy(EQRealtimeStats *stats) {
    free(stats);
}

void EQRealtimeStatsReset(EQRealtimeStats *stats) {
    if (stats == NULL) {
        return;
    }
    atomic_store_explicit(&stats->callbackCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->frameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->formatMismatchCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->dspConfigurationApplyCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->nonFiniteOutputCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->processorOverloadCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->lastTimestampDeltaNanos, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->lastProcessingNanos, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->maximumProcessingNanos, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->lastInputBufferCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->lastOutputBufferCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->lastFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->activeBandCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->crossfadeFramesRemaining, 0, memory_order_relaxed);
}

EQRealtimeStatsSnapshot EQRealtimeStatsRead(const EQRealtimeStats *stats) {
    if (stats == NULL) {
        return (EQRealtimeStatsSnapshot){0};
    }

    return (EQRealtimeStatsSnapshot){
        .callbackCount = atomic_load_explicit(&stats->callbackCount, memory_order_relaxed),
        .frameCount = atomic_load_explicit(&stats->frameCount, memory_order_relaxed),
        .formatMismatchCount = atomic_load_explicit(&stats->formatMismatchCount, memory_order_relaxed),
        .dspConfigurationApplyCount = atomic_load_explicit(&stats->dspConfigurationApplyCount, memory_order_relaxed),
        .nonFiniteOutputCount = atomic_load_explicit(&stats->nonFiniteOutputCount, memory_order_relaxed),
        .processorOverloadCount = atomic_load_explicit(&stats->processorOverloadCount, memory_order_relaxed),
        .lastTimestampDeltaNanos = atomic_load_explicit(&stats->lastTimestampDeltaNanos, memory_order_relaxed),
        .lastProcessingNanos = atomic_load_explicit(&stats->lastProcessingNanos, memory_order_relaxed),
        .maximumProcessingNanos = atomic_load_explicit(&stats->maximumProcessingNanos, memory_order_relaxed),
        .lastInputBufferCount = atomic_load_explicit(&stats->lastInputBufferCount, memory_order_relaxed),
        .lastOutputBufferCount = atomic_load_explicit(&stats->lastOutputBufferCount, memory_order_relaxed),
        .lastFrameCount = atomic_load_explicit(&stats->lastFrameCount, memory_order_relaxed),
        .activeBandCount = atomic_load_explicit(&stats->activeBandCount, memory_order_relaxed),
        .crossfadeFramesRemaining = atomic_load_explicit(&stats->crossfadeFramesRemaining, memory_order_relaxed),
    };
}

void EQRealtimeStatsRecordProcessorOverload(EQRealtimeStats *stats) {
    if (stats != NULL) {
        atomic_fetch_add_explicit(&stats->processorOverloadCount, 1, memory_order_relaxed);
    }
}

EQRealtimeDSP *EQRealtimeDSPCreate(void) {
    EQRealtimeDSP *dsp = calloc(1, sizeof(EQRealtimeDSP));
    if (dsp != NULL) {
        dsp->banks[0].preampLinear = 1.0;
        dsp->banks[1].preampLinear = 1.0;
        atomic_store_explicit(&dsp->mailbox.preampBits, EQDoubleBits(1.0), memory_order_relaxed);
    }
    return dsp;
}

void EQRealtimeDSPDestroy(EQRealtimeDSP *dsp) {
    free(dsp);
}

void EQRealtimeDSPReset(EQRealtimeDSP *dsp) {
    if (dsp == NULL) {
        return;
    }
    memset(dsp->banks, 0, sizeof(dsp->banks));
    dsp->banks[0].preampLinear = 1.0;
    dsp->banks[1].preampLinear = 1.0;
    dsp->lastAppliedGeneration = 0;
    dsp->fadingToGeneration = 0;
    dsp->activeBankIndex = 0;
    dsp->fadeTargetBankIndex = 0;
    dsp->crossfadeFramesTotal = 0;
    dsp->crossfadeFramesRemaining = 0;
}

bool EQRealtimeDSPSetConfiguration(
    EQRealtimeDSP *dsp,
    const EQBiquadCoefficients *coefficients,
    uint32_t bandCount,
    double preampLinear,
    uint32_t crossfadeFrames
) {
    if (dsp == NULL || bandCount > EQRealtimeDSPMaximumBandCount ||
        (bandCount > 0 && coefficients == NULL) || !isfinite(preampLinear) ||
        preampLinear < 0.0) {
        return false;
    }
    for (uint32_t band = 0; band < bandCount; ++band) {
        if (!EQCoefficientsAreValid(coefficients[band])) {
            return false;
        }
    }

    uint64_t current = atomic_load_explicit(&dsp->mailbox.generation, memory_order_relaxed);
    if ((current & 1u) != 0) {
        ++current;
    }
    atomic_store_explicit(&dsp->mailbox.generation, current + 1, memory_order_release);
    atomic_thread_fence(memory_order_seq_cst);
    for (uint32_t band = 0; band < bandCount; ++band) {
        const double values[5] = {
            coefficients[band].b0,
            coefficients[band].b1,
            coefficients[band].b2,
            coefficients[band].a1,
            coefficients[band].a2,
        };
        for (uint32_t value = 0; value < 5; ++value) {
            atomic_store_explicit(
                &dsp->mailbox.coefficientBits[band][value],
                EQDoubleBits(values[value]),
                memory_order_relaxed
            );
        }
    }
    atomic_store_explicit(&dsp->mailbox.preampBits, EQDoubleBits(preampLinear), memory_order_relaxed);
    atomic_store_explicit(&dsp->mailbox.bandCount, bandCount, memory_order_relaxed);
    atomic_store_explicit(&dsp->mailbox.crossfadeFrames, crossfadeFrames, memory_order_relaxed);
    atomic_thread_fence(memory_order_seq_cst);
    atomic_store_explicit(&dsp->mailbox.generation, current + 2, memory_order_release);
    return true;
}

static bool EQDSPReadMailbox(
    EQRealtimeDSP *dsp,
    EQDSPBank *destination,
    uint32_t *crossfadeFrames,
    uint64_t *generation
) {
    uint64_t before = atomic_load_explicit(&dsp->mailbox.generation, memory_order_acquire);
    if ((before & 1u) != 0 || before == dsp->lastAppliedGeneration) {
        return false;
    }

    uint32_t count = atomic_load_explicit(&dsp->mailbox.bandCount, memory_order_relaxed);
    if (count > EQRealtimeDSPMaximumBandCount) {
        return false;
    }
    destination->bandCount = count;
    destination->preampLinear = EQDoubleFromBits(
        atomic_load_explicit(&dsp->mailbox.preampBits, memory_order_relaxed)
    );
    *crossfadeFrames = atomic_load_explicit(&dsp->mailbox.crossfadeFrames, memory_order_relaxed);

    for (uint32_t band = 0; band < count; ++band) {
        double values[5];
        for (uint32_t value = 0; value < 5; ++value) {
            values[value] = EQDoubleFromBits(atomic_load_explicit(
                &dsp->mailbox.coefficientBits[band][value],
                memory_order_relaxed
            ));
        }
        destination->coefficients[band] = (EQBiquadCoefficients){
            .b0 = values[0],
            .b1 = values[1],
            .b2 = values[2],
            .a1 = values[3],
            .a2 = values[4],
        };
    }

    atomic_thread_fence(memory_order_acquire);
    uint64_t after = atomic_load_explicit(&dsp->mailbox.generation, memory_order_acquire);
    if (before != after || (after & 1u) != 0) {
        return false;
    }
    *generation = after;
    return true;
}

static void EQDSPPreparePendingConfiguration(EQRealtimeDSP *dsp, EQRealtimeStats *stats) {
    if (dsp == NULL || dsp->crossfadeFramesRemaining != 0) {
        return;
    }

    uint32_t target = 1u - dsp->activeBankIndex;
    uint32_t crossfadeFrames = 0;
    uint64_t generation = 0;
    if (!EQDSPReadMailbox(
            dsp,
            &dsp->banks[target],
            &crossfadeFrames,
            &generation
        )) {
        return;
    }

    memset(dsp->banks[target].states, 0, sizeof(dsp->banks[target].states));
    dsp->fadeTargetBankIndex = target;
    dsp->fadingToGeneration = generation;
    dsp->crossfadeFramesTotal = crossfadeFrames;
    dsp->crossfadeFramesRemaining = crossfadeFrames;
    atomic_fetch_add_explicit(&stats->dspConfigurationApplyCount, 1, memory_order_relaxed);

    if (crossfadeFrames == 0) {
        dsp->activeBankIndex = target;
        dsp->lastAppliedGeneration = generation;
    }
}

static double EQDSPProcessBankSample(
    EQDSPBank *bank,
    double input,
    uint32_t channel
) {
    double sample = input * bank->preampLinear;
    for (uint32_t band = 0; band < bank->bandCount; ++band) {
        EQBiquadCoefficients c = bank->coefficients[band];
        EQBiquadState *state = &bank->states[channel][band];
        double output = c.b0 * sample + state->z1;
        state->z1 = c.b1 * sample - c.a1 * output + state->z2;
        state->z2 = c.b2 * sample - c.a2 * output;
        sample = output;
    }
    return sample;
}

static uint32_t EQChannelCount(const AudioBufferList *list) {
    uint32_t channels = 0;
    for (uint32_t index = 0; index < list->mNumberBuffers; ++index) {
        channels += list->mBuffers[index].mNumberChannels;
    }
    return channels;
}

static uint32_t EQFrameCount(const AudioBufferList *list) {
    uint32_t frames = UINT32_MAX;
    bool foundBuffer = false;

    for (uint32_t index = 0; index < list->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &list->mBuffers[index];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            continue;
        }
        uint32_t bufferFrames = buffer->mDataByteSize /
            ((uint32_t)sizeof(float) * buffer->mNumberChannels);
        frames = bufferFrames < frames ? bufferFrames : frames;
        foundBuffer = true;
    }
    return foundBuffer ? frames : 0;
}

static const float *EQInputSamplePointer(
    const AudioBufferList *list,
    uint32_t frame,
    uint32_t channel
) {
    uint32_t channelBase = 0;
    for (uint32_t index = 0; index < list->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &list->mBuffers[index];
        uint32_t nextChannelBase = channelBase + buffer->mNumberChannels;
        if (channel < nextChannelBase && buffer->mData != NULL) {
            uint32_t localChannel = channel - channelBase;
            const float *samples = buffer->mData;
            return &samples[frame * buffer->mNumberChannels + localChannel];
        }
        channelBase = nextChannelBase;
    }
    return NULL;
}

static float *EQOutputSamplePointer(
    AudioBufferList *list,
    uint32_t frame,
    uint32_t channel
) {
    uint32_t channelBase = 0;
    for (uint32_t index = 0; index < list->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &list->mBuffers[index];
        uint32_t nextChannelBase = channelBase + buffer->mNumberChannels;
        if (channel < nextChannelBase && buffer->mData != NULL) {
            uint32_t localChannel = channel - channelBase;
            float *samples = buffer->mData;
            return &samples[frame * buffer->mNumberChannels + localChannel];
        }
        channelBase = nextChannelBase;
    }
    return NULL;
}

static void EQStoreMaximum(_Atomic uint64_t *destination, uint64_t value) {
    uint64_t current = atomic_load_explicit(destination, memory_order_relaxed);
    while (value > current && !atomic_compare_exchange_weak_explicit(
        destination,
        &current,
        value,
        memory_order_relaxed,
        memory_order_relaxed
    )) {}
}

void EQRealtimeProcess(
    EQRealtimeDSP *dsp,
    EQRealtimeStats *stats,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *outputData,
    const AudioTimeStamp *outputTime,
    bool supportsFloat32PCM
) {
    if (stats == NULL || inputData == NULL || outputData == NULL) {
        return;
    }
    uint64_t processingStart = AudioGetCurrentHostTime();

    atomic_fetch_add_explicit(&stats->callbackCount, 1, memory_order_relaxed);
    atomic_store_explicit(&stats->lastInputBufferCount, inputData->mNumberBuffers, memory_order_relaxed);
    atomic_store_explicit(&stats->lastOutputBufferCount, outputData->mNumberBuffers, memory_order_relaxed);

    for (uint32_t index = 0; index < outputData->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &outputData->mBuffers[index];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }

    uint32_t inputChannels = EQChannelCount(inputData);
    uint32_t outputChannels = EQChannelCount(outputData);
    uint32_t inputFrames = EQFrameCount(inputData);
    uint32_t outputFrames = EQFrameCount(outputData);
    uint32_t frames = inputFrames < outputFrames ? inputFrames : outputFrames;

    if (!supportsFloat32PCM || inputChannels == 0 || inputChannels != outputChannels ||
        inputChannels > EQRealtimeDSPMaximumChannelCount || frames == 0) {
        atomic_fetch_add_explicit(&stats->formatMismatchCount, 1, memory_order_relaxed);
        atomic_store_explicit(&stats->lastFrameCount, 0, memory_order_relaxed);
        return;
    }

    EQDSPPreparePendingConfiguration(dsp, stats);

    for (uint32_t frame = 0; frame < frames; ++frame) {
        bool isCrossfading = dsp != NULL && dsp->crossfadeFramesRemaining > 0;
        double crossfade = 0.0;
        if (isCrossfading) {
            crossfade = (double)(dsp->crossfadeFramesTotal - dsp->crossfadeFramesRemaining + 1) /
                (double)dsp->crossfadeFramesTotal;
        }

        for (uint32_t channel = 0; channel < inputChannels; ++channel) {
            const float *input = EQInputSamplePointer(inputData, frame, channel);
            float *output = EQOutputSamplePointer(outputData, frame, channel);
            if (input == NULL || output == NULL) {
                continue;
            }

            double sample = *input;
            if (dsp != NULL) {
                double active = EQDSPProcessBankSample(
                    &dsp->banks[dsp->activeBankIndex],
                    sample,
                    channel
                );
                if (isCrossfading) {
                    double target = EQDSPProcessBankSample(
                        &dsp->banks[dsp->fadeTargetBankIndex],
                        sample,
                        channel
                    );
                    sample = active + (target - active) * crossfade;
                } else {
                    sample = active;
                }
            }

            if (isfinite(sample)) {
                *output = (float)sample;
            } else {
                *output = 0.0f;
                atomic_fetch_add_explicit(&stats->nonFiniteOutputCount, 1, memory_order_relaxed);
            }
        }

        if (isCrossfading) {
            --dsp->crossfadeFramesRemaining;
            if (dsp->crossfadeFramesRemaining == 0) {
                dsp->activeBankIndex = dsp->fadeTargetBankIndex;
                dsp->lastAppliedGeneration = dsp->fadingToGeneration;
            }
        }
    }

    atomic_fetch_add_explicit(&stats->frameCount, frames, memory_order_relaxed);
    atomic_store_explicit(&stats->lastFrameCount, frames, memory_order_relaxed);
    if (dsp != NULL) {
        uint32_t displayedBank = dsp->crossfadeFramesRemaining > 0
            ? dsp->fadeTargetBankIndex
            : dsp->activeBankIndex;
        atomic_store_explicit(
            &stats->activeBandCount,
            dsp->banks[displayedBank].bandCount,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &stats->crossfadeFramesRemaining,
            dsp->crossfadeFramesRemaining,
            memory_order_relaxed
        );
    }

    if (inputTime != NULL && outputTime != NULL &&
        (inputTime->mFlags & kAudioTimeStampHostTimeValid) != 0 &&
        (outputTime->mFlags & kAudioTimeStampHostTimeValid) != 0 &&
        outputTime->mHostTime >= inputTime->mHostTime) {
        uint64_t delta = AudioConvertHostTimeToNanos(outputTime->mHostTime - inputTime->mHostTime);
        atomic_store_explicit(&stats->lastTimestampDeltaNanos, delta, memory_order_relaxed);
    }

    uint64_t elapsed = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime() - processingStart);
    atomic_store_explicit(&stats->lastProcessingNanos, elapsed, memory_order_relaxed);
    EQStoreMaximum(&stats->maximumProcessingNanos, elapsed);
}

void EQRealtimePassThrough(
    EQRealtimeStats *stats,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *outputData,
    const AudioTimeStamp *outputTime,
    bool supportsFloat32PCM
) {
    EQRealtimeProcess(
        NULL,
        stats,
        inputData,
        inputTime,
        outputData,
        outputTime,
        supportsFloat32PCM
    );
}

bool EQRealtimeBridgeSelfTest(void) {
    float left[] = {1.0f, 2.0f};
    float right[] = {10.0f, 20.0f};
    float interleaved[] = {0.0f, 0.0f, 0.0f, 0.0f};

    struct {
        uint32_t mNumberBuffers;
        AudioBuffer mBuffers[2];
    } planarInput = {
        .mNumberBuffers = 2,
        .mBuffers = {
            {.mNumberChannels = 1, .mDataByteSize = sizeof(left), .mData = left},
            {.mNumberChannels = 1, .mDataByteSize = sizeof(right), .mData = right},
        },
    };
    AudioBufferList interleavedOutput = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 2,
            .mDataByteSize = sizeof(interleaved),
            .mData = interleaved,
        }},
    };

    EQRealtimeStats *stats = EQRealtimeStatsCreate();
    if (stats == NULL) {
        return false;
    }
    EQRealtimePassThrough(
        stats,
        (const AudioBufferList *)&planarInput,
        NULL,
        &interleavedOutput,
        NULL,
        true
    );
    EQRealtimeStatsSnapshot snapshot = EQRealtimeStatsRead(stats);
    EQRealtimeStatsDestroy(stats);

    return interleaved[0] == 1.0f && interleaved[1] == 10.0f &&
        interleaved[2] == 2.0f && interleaved[3] == 20.0f &&
        snapshot.callbackCount == 1 && snapshot.frameCount == 2 &&
        snapshot.formatMismatchCount == 0;
}

bool EQRealtimeDSPImpulseSelfTest(void) {
    float inputSamples[] = {1.0f, 0.0f, 0.0f};
    float outputSamples[] = {0.0f, 0.0f, 0.0f};
    AudioBufferList input = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 1,
            .mDataByteSize = sizeof(inputSamples),
            .mData = inputSamples,
        }},
    };
    AudioBufferList output = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 1,
            .mDataByteSize = sizeof(outputSamples),
            .mData = outputSamples,
        }},
    };
    EQBiquadCoefficients coefficients = {
        .b0 = 0.5,
        .b1 = 0.25,
        .b2 = 0.0,
        .a1 = 0.0,
        .a2 = 0.0,
    };

    EQRealtimeDSP *dsp = EQRealtimeDSPCreate();
    EQRealtimeStats *stats = EQRealtimeStatsCreate();
    if (dsp == NULL || stats == NULL ||
        !EQRealtimeDSPSetConfiguration(dsp, &coefficients, 1, 1.0, 0)) {
        EQRealtimeDSPDestroy(dsp);
        EQRealtimeStatsDestroy(stats);
        return false;
    }
    EQRealtimeProcess(dsp, stats, &input, NULL, &output, NULL, true);
    EQRealtimeStatsSnapshot snapshot = EQRealtimeStatsRead(stats);
    EQRealtimeDSPDestroy(dsp);
    EQRealtimeStatsDestroy(stats);

    return outputSamples[0] == 0.5f && outputSamples[1] == 0.25f &&
        outputSamples[2] == 0.0f && snapshot.activeBandCount == 1 &&
        snapshot.dspConfigurationApplyCount == 1 && snapshot.nonFiniteOutputCount == 0;
}

bool EQRealtimeDSPCrossfadeSelfTest(void) {
    float activationInput[] = {1.0f};
    float activationOutput[] = {0.0f};
    float transitionInput[] = {1.0f, 1.0f, 1.0f, 1.0f};
    float transitionOutput[] = {0.0f, 0.0f, 0.0f, 0.0f};
    AudioBufferList activationIn = {
        .mNumberBuffers = 1,
        .mBuffers = {{1, sizeof(activationInput), activationInput}},
    };
    AudioBufferList activationOut = {
        .mNumberBuffers = 1,
        .mBuffers = {{1, sizeof(activationOutput), activationOutput}},
    };
    AudioBufferList transitionIn = {
        .mNumberBuffers = 1,
        .mBuffers = {{1, sizeof(transitionInput), transitionInput}},
    };
    AudioBufferList transitionOut = {
        .mNumberBuffers = 1,
        .mBuffers = {{1, sizeof(transitionOutput), transitionOutput}},
    };
    EQBiquadCoefficients identity = {1.0, 0.0, 0.0, 0.0, 0.0};
    EQBiquadCoefficients mute = {0.0, 0.0, 0.0, 0.0, 0.0};

    EQRealtimeDSP *dsp = EQRealtimeDSPCreate();
    EQRealtimeStats *stats = EQRealtimeStatsCreate();
    if (dsp == NULL || stats == NULL ||
        !EQRealtimeDSPSetConfiguration(dsp, &identity, 1, 1.0, 0)) {
        EQRealtimeDSPDestroy(dsp);
        EQRealtimeStatsDestroy(stats);
        return false;
    }
    EQRealtimeProcess(dsp, stats, &activationIn, NULL, &activationOut, NULL, true);
    if (!EQRealtimeDSPSetConfiguration(dsp, &mute, 1, 1.0, 4)) {
        EQRealtimeDSPDestroy(dsp);
        EQRealtimeStatsDestroy(stats);
        return false;
    }
    EQRealtimeProcess(dsp, stats, &transitionIn, NULL, &transitionOut, NULL, true);
    EQRealtimeStatsSnapshot snapshot = EQRealtimeStatsRead(stats);
    EQRealtimeDSPDestroy(dsp);
    EQRealtimeStatsDestroy(stats);

    return activationOutput[0] == 1.0f &&
        transitionOutput[0] == 0.75f && transitionOutput[1] == 0.5f &&
        transitionOutput[2] == 0.25f && transitionOutput[3] == 0.0f &&
        snapshot.dspConfigurationApplyCount == 2 &&
        snapshot.crossfadeFramesRemaining == 0;
}
