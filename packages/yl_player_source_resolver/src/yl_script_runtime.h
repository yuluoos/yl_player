#ifndef YL_SCRIPT_RUNTIME_H
#define YL_SCRIPT_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
#define YL_JS_EXPORT __attribute__((visibility("default")))
typedef struct yl_js_job yl_js_job;

/* Inputs are copied. NULL means invalid bounds, admission exhaustion or native
 * allocation failure. A handle has one owner; never race destroy with another
 * API call, and never reuse a handle after a successful destroy. */
YL_JS_EXPORT yl_js_job *yl_js_start(const char *source, size_t source_len,
                                  const char *parameter, size_t parameter_len,
                                  uint32_t timeout_ms, size_t heap_bytes,
                                  size_t stack_bytes);
/* 0 running; 1 success; 2 timeout; 3 cancelled; 4 resource limit; 5 syntax;
 * 6 execution; 7 unsupported host API; 8 invalid result; 9 host transport.
 * Terminal values are published only after runtime/context destruction. */
YL_JS_EXPORT int yl_js_status(yl_js_job *job);
/* Each request is delivered at most once. Returned JSON copies are freed with
 * yl_js_free, and must receive exactly one reply while the job remains live. */
YL_JS_EXPORT char *yl_js_take_request(yl_js_job *job);
YL_JS_EXPORT int yl_js_reply(yl_js_job *job, const char *json, size_t len,
                            int error_code);
YL_JS_EXPORT char *yl_js_result(yl_js_job *job);
YL_JS_EXPORT void yl_js_cancel(yl_js_job *job);
/* Returns 0 while running; otherwise joins the completed worker and frees the
 * caller-owned handle. Cancellation alone does not free that handle. */
YL_JS_EXPORT int yl_js_destroy(yl_js_job *job);
YL_JS_EXPORT void yl_js_free(void *buffer);
#endif
