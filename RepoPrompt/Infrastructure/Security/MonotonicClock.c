#include "MonotonicClock.h"

#include <mach/mach_time.h>


double rp_continuous_time_seconds(void) {
	static mach_timebase_info_data_t timebase = {0, 0};
	if (timebase.denom == 0) {
		(void)mach_timebase_info(&timebase);
	}

	const uint64_t ticks = mach_continuous_time();
	const long double nanos = ((long double)ticks * (long double)timebase.numer) / (long double)timebase.denom;
	return (double)(nanos / 1000000000.0L);
}
