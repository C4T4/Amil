#ifndef AT_PLUGIN_H
#define AT_PLUGIN_H

#include "at_control.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AT_PLUGIN_ABI 1

/*
 * Transport plugin ABI. Unix is in-process; HTTP, Tailscale, WoW, and an
 * MCP server are dylibs that speak this. They never import AppKit or the
 * store — they call into the bus.
 *
 * MCP sketch: tools/list = bus ops; tools/call = host->call_capped(op, args).
 */

typedef struct ATPluginHost {
    uint32_t abi;
    uint32_t caps;
    const char *support_dir;
    const char *config_json;
    int  (*call)(const char *op, const char *json_args, char **json_out);
    int  (*call_capped)(const char *op, const char *json_args, char **json_out, uint32_t have);
    void (*free)(char *p);
    int  (*watch_fd)(int fd, void (*on_read)(int fd, void *ctx), void *ctx);
    int  (*unwatch_fd)(int fd);
    int  (*log)(int level, const char *msg);
} ATPluginHost;

int  at_plugin_abi(void);
const char *at_plugin_name(void);
int  at_plugin_init(ATPluginHost *host);
void at_plugin_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
