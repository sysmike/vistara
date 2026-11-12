#ifndef VISTARA_PROBE_H
#define VISTARA_PROBE_H

#include <stdint.h>

/// Milliseconds on a clock that only moves forward.
uint64_t vistara_monotonic_ms(void);

/// Tries one TCP connection to the first address of `hostname`:`port` and
/// returns how it failed: an errno value such as ECONNREFUSED or
/// EHOSTUNREACH, ETIMEDOUT after `timeout_ms`, or 0 when it connected or
/// the name did not resolve. The connection is closed at once.
int vistara_probe_tcp_error(const char *hostname, int port, int timeout_ms);

#endif
