#ifndef AT_CONTROL_H
#define AT_CONTROL_H

#include "aterminal.h"
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AT_CONTROL_ABI 1

#define AT_CAP_READ    (1u << 0)
#define AT_CAP_FOCUS   (1u << 1)
#define AT_CAP_INPUT   (1u << 2)
#define AT_CAP_SESSION (1u << 3)
#define AT_CAP_LAYOUT  (1u << 4)
#define AT_CAP_FS      (1u << 5)
#define AT_CAP_ADMIN   (1u << 6)
#define AT_CAP_PAIR    (1u << 7)

#define AT_CAP_LOCAL_DEFAULT (AT_CAP_READ | AT_CAP_FOCUS | AT_CAP_INPUT | \
    AT_CAP_SESSION | AT_CAP_LAYOUT | AT_CAP_FS | AT_CAP_PAIR)

/*
 * The bus is the product. Unix, HTTP, MCP, and WoW are transports:
 * they authenticate a connection, compute `have`, and call
 * at_control_call_capped. An MCP server is a transport that maps
 * tools/call onto bus ops — it does not own the store or PTYs.
 */

typedef struct ATControlUI {
    void *ctx;
    int  (*reload)(void *ctx);
    int  (*focus_workspace)(void *ctx, const char *workspace_id);
    int  (*focus_tab)(void *ctx, const char *workspace_id, const char *tab_id);
    int  (*focus_pane)(void *ctx, const char *pane_id, int make_key);
    int  (*pane_write)(void *ctx, const char *pane_id, const void *bytes, size_t n, int submit);
    int  (*pane_paste_path)(void *ctx, const char *pane_id, const char *path);
    int  (*pane_paste_png)(void *ctx, const char *pane_id, const void *png, size_t n);
    /* 0..3 is ATActivity (0 = none is a valid snapshot). -1 = unknown id. */
    int  (*pane_activity)(void *ctx, const char *pane_id);
    int  (*tab_activity)(void *ctx, const char *tab_id);
    int  (*workspace_activity)(void *ctx, const char *workspace_id);
    int  (*tab_add)(void *ctx, const char *workspace_id, const char *agent, const char *session);
    int  (*tab_close)(void *ctx, const char *workspace_id, const char *tab_id);
    int  (*pane_close)(void *ctx, const char *pane_id);
    int  (*pane_split)(void *ctx, const char *workspace_id, const char *tab_id, int horiz);
    int  (*workspace_create)(void *ctx, const char *name, const char *const *folders, uint32_t n, const char *agent);
    int  (*workspace_close)(void *ctx, const char *workspace_id);
} ATControlUI;

typedef struct ATControlIO {
    void *ctx;
    int  (*watch_fd)(void *ctx, int fd, void (*on_read)(int, void *), void *user);
    int  (*unwatch_fd)(void *ctx, int fd);
} ATControlIO;

/* ui and io may be NULL (bus-only init; no unix listen). */
int  at_control_start(ATStore *store, const ATControlUI *ui, const ATControlIO *io);
void at_control_stop(void);

/* Uncapped. App.m / tests only (TCB). Transports and plugins must not dlsym this. */
int  at_control_call(const char *op, const char *json_args, char **json_out);

/* Transports: have is the connection's granted mask. Final = have ∩ op.need. */
int  at_control_call_capped(const char *op, const char *json_args, char **json_out, uint32_t have);

void at_control_free(char *p);
const char *at_control_error(void);

/* Main thread. No-op if no subscribers. */
void at_control_emit(const char *json_event);

/* Settings. Catalog is discovered dylibs plus enabled stems. */
int  at_control_forced_off(void);
int  at_control_unix_on(void);
int  at_control_set_unix(int on);
int  at_control_git_on(void); /* built-in git tracking; default on */
int  at_control_background_on(void); /* keep agents alive when the window closes */
int  at_control_yolo(void); /* skip agent permission prompts; default off */
int  at_control_set_yolo(int on);
uint32_t at_control_ext_count(void);
const char *at_control_ext_id(uint32_t i);
const char *at_control_ext_title(uint32_t i);
int  at_control_ext_enabled(uint32_t i);
int  at_control_ext_loaded(uint32_t i);
int  at_control_ext_present(uint32_t i);
const char *at_control_ext_requires(uint32_t i); /* "core" or "core, mcp"; NULL if none */
int  at_control_ext_deps_ok(uint32_t i);
int  at_control_set_ext(const char *id, int on);
int  at_control_apply(void); /* write control.json and reload transports */
const char *at_control_plugin_dir(void);

#ifdef __cplusplus
}
#endif

#endif
