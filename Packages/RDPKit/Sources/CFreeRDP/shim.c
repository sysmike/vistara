#include "CFreeRDP.h"

#include <stdlib.h>

#include <freerdp/freerdp.h>

struct vistara_session {
    freerdp *instance;
};

const char *vistara_freerdp_version(void) {
    return freerdp_get_version_string();
}

vistara_session *vistara_session_create(void) {
    vistara_session *session = calloc(1, sizeof(*session));
    if (!session) {
        return NULL;
    }

    session->instance = freerdp_new();
    if (!session->instance) {
        free(session);
        return NULL;
    }

    // freerdp_context_new() allocates ContextSize bytes for the context.
    session->instance->ContextSize = sizeof(rdpContext);
    if (!freerdp_context_new(session->instance)) {
        freerdp_free(session->instance);
        free(session);
        return NULL;
    }

    return session;
}

void vistara_session_destroy(vistara_session *session) {
    if (!session) {
        return;
    }
    freerdp_context_free(session->instance);
    freerdp_free(session->instance);
    free(session);
}
