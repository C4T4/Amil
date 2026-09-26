#ifndef ATERMINAL_H
#define ATERMINAL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ATStore ATStore;

ATStore *at_store_open(void);
void at_store_close(ATStore *store);
int at_store_save(ATStore *store);

uint32_t at_store_workspace_count(const ATStore *store);
int32_t at_store_active_index(const ATStore *store);
void at_store_set_active(ATStore *store, int32_t index);

const char *at_store_id(const ATStore *store, uint32_t index);
const char *at_store_name(const ATStore *store, uint32_t index);
const char *at_store_agent(const ATStore *store, uint32_t index);
uint32_t at_store_folder_count(const ATStore *store, uint32_t index);
const char *at_store_folder(const ATStore *store, uint32_t index, uint32_t folder);

/* Returned pointers are valid until the next mutating call. */
int at_store_add_workspace(
    ATStore *store,
    const char *name,
    const char *const *folders,
    uint32_t folder_count,
    const char *agent);
int at_store_add_folder(ATStore *store, uint32_t index, const char *path);
int at_store_remove_folder(ATStore *store, uint32_t index, uint32_t folder);
int at_store_remove_workspace(ATStore *store, uint32_t index);
int at_store_set_name(ATStore *store, uint32_t index, const char *name);
int at_store_set_agent(ATStore *store, uint32_t index, const char *agent);

uint32_t at_store_tab_count(const ATStore *store, uint32_t workspace);
int32_t at_store_active_tab(const ATStore *store, uint32_t workspace);
void at_store_set_active_tab(ATStore *store, uint32_t workspace, int32_t tab);
const char *at_store_tab_id(const ATStore *store, uint32_t workspace, uint32_t tab);
const char *at_store_tab_agent(const ATStore *store, uint32_t workspace, uint32_t tab);
/* NULL when unnamed; caller falls back to the agent display name. */
const char *at_store_tab_name(const ATStore *store, uint32_t workspace, uint32_t tab);
/* Pass "" to clear the name and restore the agent fallback. */
int at_store_set_tab_name(ATStore *store, uint32_t workspace, uint32_t tab, const char *name);
const char *at_store_tab_session(const ATStore *store, uint32_t workspace, uint32_t tab);
int at_store_set_tab_session(ATStore *store, const char *tab_id, const char *session);
int at_store_layout_build(ATStore *store, uint32_t workspace, uint32_t tab);
uint32_t at_store_layout_count(const ATStore *store);
uint8_t at_store_layout_kind(const ATStore *store, uint32_t index);
float at_store_layout_ratio(const ATStore *store, uint32_t index);
int32_t at_store_layout_a(const ATStore *store, uint32_t index);
int32_t at_store_layout_b(const ATStore *store, uint32_t index);
const char *at_store_layout_pane_id(const ATStore *store, uint32_t index);
const char *at_store_layout_pane_agent(const ATStore *store, uint32_t index);
const char *at_store_layout_pane_session(const ATStore *store, uint32_t index);
const char *at_store_active_pane(const ATStore *store, uint32_t workspace, uint32_t tab);
int at_store_set_active_pane(ATStore *store, uint32_t workspace, uint32_t tab, const char *pane_id);
int at_store_set_split_ratio(ATStore *store, uint32_t index, float ratio);
int at_store_split(ATStore *store, uint32_t workspace, uint32_t tab, int horiz);
int at_store_close_pane(ATStore *store, uint32_t workspace, uint32_t tab, const char *pane_id);
uint32_t at_store_history_count(const ATStore *store);
const char *at_store_history_session(const ATStore *store, uint32_t index);
const char *at_store_history_agent(const ATStore *store, uint32_t index);
const char *at_store_history_cwd(const ATStore *store, uint32_t index);
uint32_t at_store_history_folder_count(const ATStore *store, uint32_t index);
const char *at_store_history_folder(const ATStore *store, uint32_t index, uint32_t folder);
const char *at_store_history_title(const ATStore *store, uint32_t index);
int64_t at_store_history_updated(const ATStore *store, uint32_t index);
int at_store_add_tab(ATStore *store, uint32_t workspace, const char *agent);
int at_store_remove_tab(ATStore *store, uint32_t workspace, uint32_t tab);

const char *at_store_error(void);
const char *at_store_dir(const ATStore *store);
int at_store_recovered(const ATStore *store);
const char *at_store_home(const ATStore *store);
int at_store_set_home(ATStore *store, const char *path);

#ifdef __cplusplus
}
#endif

#endif
