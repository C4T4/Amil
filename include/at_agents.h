#ifndef AT_AGENTS_H
#define AT_AGENTS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ATAgentInfo {
    const char *id;
    const char *name;
    const char *model;
    const char *icon;
    /* Executable to run in the workspace pty. Looked up on the login PATH. */
    const char *cmd;
    /* Space-separated flags always passed to that executable. */
    const char *flags;
} ATAgentInfo;

uint32_t at_agent_count(void);
const ATAgentInfo *at_agent_at(uint32_t index);
const ATAgentInfo *at_agent_find(const char *id);

#ifdef __cplusplus
}
#endif

#endif
