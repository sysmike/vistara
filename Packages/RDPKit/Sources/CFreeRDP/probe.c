// Only system headers here: WinPR redefines some socket functions.
#include "probe.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

uint64_t vistara_monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

int vistara_probe_tcp_error(const char *hostname, int port, int timeout_ms) {
    char service[16];
    snprintf(service, sizeof service, "%d", port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *result = NULL;
    if (getaddrinfo(hostname, service, &hints, &result) != 0 || !result) {
        return 0;
    }

    int error = 0;
    const int fd = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (fd >= 0) {
        const int flags = fcntl(fd, F_GETFL, 0);
        (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        if (connect(fd, result->ai_addr, result->ai_addrlen) != 0) {
            if (errno != EINPROGRESS) {
                error = errno;
            } else {
                struct pollfd target = {.fd = fd, .events = POLLOUT, .revents = 0};
                int ready;
                do {
                    ready = poll(&target, 1, timeout_ms);
                } while (ready < 0 && errno == EINTR);
                if (ready == 0) {
                    error = ETIMEDOUT;
                } else if (ready > 0) {
                    socklen_t length = sizeof error;
                    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0) {
                        error = 0;
                    }
                }
            }
        }
        close(fd);
    }
    freeaddrinfo(result);
    return error;
}
