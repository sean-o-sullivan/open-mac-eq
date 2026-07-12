#ifndef RealtimeBridge_h
#define RealtimeBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct EQRealtimeStats EQRealtimeStats;
typedef struct EQRealtimeDSP EQRealtimeDSP;

enum {
    EQRealtimeDSPMaximumBandCount = 64,
    EQRealtimeDSPMaximumChannelCount = 8,
};

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} EQBiquadCoefficients;

typedef struct {
    uint64_t callbackCount;
    uint64_t frameCount;
    uint64_t formatMismatchCount;
    uint64_t dspConfigurationApplyCount;
    uint64_t nonFiniteOutputCount;
    uint64_t processorOverloadCount;
    uint64_t aboveFullScaleSampleCount;
    uint64_t lastTimestampDeltaNanos;
    uint64_t lastProcessingNanos;
    uint64_t maximumProcessingNanos;
    double lastOutputPeakMagnitude;
    double maximumOutputPeakMagnitude;
    uint32_t lastInputBufferCount;
    uint32_t lastOutputBufferCount;
    uint32_t lastFrameCount;
    uint32_t activeBandCount;
    uint32_t crossfadeFramesRemaining;
} EQRealtimeStatsSnapshot;

EQRealtimeStats *EQRealtimeStatsCreate(void);
void EQRealtimeStatsDestroy(EQRealtimeStats *stats);
void EQRealtimeStatsReset(EQRealtimeStats *stats);
EQRealtimeStatsSnapshot EQRealtimeStatsRead(const EQRealtimeStats *stats);
void EQRealtimeStatsRecordProcessorOverload(EQRealtimeStats *stats);

EQRealtimeDSP *EQRealtimeDSPCreate(void);
void EQRealtimeDSPDestroy(EQRealtimeDSP *dsp);
void EQRealtimeDSPReset(EQRealtimeDSP *dsp);
bool EQRealtimeDSPSetConfiguration(
    EQRealtimeDSP *dsp,
    const EQBiquadCoefficients *coefficients,
    uint32_t bandCount,
    double preampLinear,
    uint32_t crossfadeFrames
);

void EQRealtimeProcess(
    EQRealtimeDSP *dsp,
    EQRealtimeStats *stats,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *outputData,
    const AudioTimeStamp *outputTime,
    bool supportsFloat32PCM
);

void EQRealtimePassThrough(
    EQRealtimeStats *stats,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *outputData,
    const AudioTimeStamp *outputTime,
    bool supportsFloat32PCM
);

bool EQRealtimeBridgeSelfTest(void);
bool EQRealtimeDSPImpulseSelfTest(void);
bool EQRealtimeDSPCrossfadeSelfTest(void);

#endif
