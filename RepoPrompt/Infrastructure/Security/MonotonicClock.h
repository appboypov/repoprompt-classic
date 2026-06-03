#ifndef MONOTONIC_CLOCK_H
#define MONOTONIC_CLOCK_H

#ifdef __cplusplus
extern "C" {
#endif

// Continuous time in seconds since boot, including sleep.
double rp_continuous_time_seconds(void);

#ifdef __cplusplus
}
#endif

#endif
