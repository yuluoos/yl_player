// Observe real QuickJS destruction without adding production test hooks.
#include "../src/quickjs/quickjs.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static atomic_int runtimes_created, runtimes_freed, contexts_created,
    contexts_freed;
static JSRuntime *observed_new_runtime(const JSMallocFunctions *f, void *opaque) {
  JSRuntime *rt = JS_NewRuntime2(f, opaque);
  if (rt) atomic_fetch_add(&runtimes_created, 1);
  return rt;
}
static JSContext *observed_new_context(JSRuntime *rt) {
  JSContext *ctx = JS_NewContext(rt);
  if (ctx) atomic_fetch_add(&contexts_created, 1);
  return ctx;
}
static void observed_free_context(JSContext *ctx) {
  JS_FreeContext(ctx);
  atomic_fetch_add(&contexts_freed, 1);
}
static void observed_free_runtime(JSRuntime *rt) {
  JS_FreeRuntime(rt);
  atomic_fetch_add(&runtimes_freed, 1);
}
// Function entry can poll too; a second interrupt callback during the sole
// public main call proves continued execution of the CPU-loop fixture.
static atomic_int loops_ready;
static _Thread_local JSInterruptHandler *worker_interrupt;
static _Thread_local int inside_main, main_polls;
static int observed_interrupt(JSRuntime *rt, void *opaque) {
  if (inside_main && ++main_polls == 2)
    atomic_fetch_add(&loops_ready, 1);
  return worker_interrupt(rt, opaque);
}
static void observed_set_interrupt(JSRuntime *rt, JSInterruptHandler *cb,
                                   void *opaque) {
  worker_interrupt = cb;
  JS_SetInterruptHandler(rt, observed_interrupt, opaque);
}
static JSValue observed_call(JSContext *ctx, JSValueConst fn,
                             JSValueConst receiver, int argc,
                             JSValueConst *argv) {
  inside_main = 1;
  main_polls = 0;
  JSValue result = JS_Call(ctx, fn, receiver, argc, argv);
  inside_main = 0;
  return result;
}
#define JS_SetInterruptHandler observed_set_interrupt
#define JS_Call observed_call
#define JS_NewRuntime2 observed_new_runtime
#define JS_NewContext observed_new_context
#define JS_FreeContext observed_free_context
#define JS_FreeRuntime observed_free_runtime
#include "../src/yl_script_runtime.c"
#undef JS_SetInterruptHandler
#undef JS_Call
#undef JS_NewRuntime2
#undef JS_NewContext
#undef JS_FreeContext
#undef JS_FreeRuntime

static int checks;
#define CHECK(x) do { \
  checks++; \
  if (!(x)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); \
    exit(1); \
  } \
} while (0)
static yl_js_job *begin(const char *source, unsigned timeout) {
  yl_js_job *job = yl_js_start(source, strlen(source), "", 0, timeout,
                              8 * 1024 * 1024, 256 * 1024);
  CHECK(job);
  return job;
}
static void await_created(int total) {
  for (int i = 0; i < 5000 && atomic_load(&contexts_created) != total; i++)
    usleep(1000);
  CHECK(atomic_load(&runtimes_created) == total);
  CHECK(atomic_load(&contexts_created) == total);
}
static void await_request(yl_js_job *job) {
  char *request = NULL;
  for (int i = 0; i < 5000 && !request; i++) {
    request = yl_js_take_request(job);
    if (!request) usleep(1000);
  }
  CHECK(request);
  yl_js_free(request);
}
static void await_status(yl_js_job *job, int expected) {
  for (int i = 0; i < 5000 && !yl_js_status(job); i++) usleep(1000);
  CHECK(yl_js_status(job) == expected);
}
static void freed(int total) {
  CHECK(atomic_load(&contexts_freed) == total);
  CHECK(atomic_load(&runtimes_freed) == total);
}
int main(void) {
  int total = 0;
  // Repeated full-capacity batches expose admission leaks as well as VM leaks.
  for (int round = 0; round < 3; round++) {
    for (int host = 0; host < 2; host++) {
      for (int timeout = 0; timeout < 2; timeout++) {
        int ready_before = atomic_load(&loops_ready);
        yl_js_job *jobs[4];
        for (int i = 0; i < 4; i++) {
          jobs[i] = begin(host
              ? "function main(){return mytv.get('https://fixture.invalid')}"
              : "function main(){while(true){}}", timeout ? 1000 : 30000);
          if (host) await_request(jobs[i]);
        }
        total += 4;
        await_created(total);
        if (!host) {
          for (int i = 0; i < 5000 &&
               atomic_load(&loops_ready) != ready_before + 4; i++)
            usleep(1000);
          CHECK(atomic_load(&loops_ready) == ready_before + 4);
        }
        freed(total - 4);
        if (!timeout)
          for (int i = 0; i < 4; i++) yl_js_cancel(jobs[i]);
        for (int i = 0; i < 4; i++) await_status(jobs[i], timeout ? 2 : 3);
        // Terminal status must already mean real context/runtime destruction.
        freed(total);
        for (int i = 0; i < 4; i++) {
          CHECK(!yl_js_result(jobs[i]));
          CHECK(!yl_js_reply(jobs[i], "null", 4, 0));
          CHECK(yl_js_destroy(jobs[i]));
        }
        yl_js_job *fresh = begin(
            "function main(){return {url:'https://fixture.invalid/fresh'}}", 1000);
        await_status(fresh, 1);
        total++;
        await_created(total);
        freed(total);
        char *result = yl_js_result(fresh);
        CHECK(result && strstr(result, "/fresh"));
        yl_js_free(result);
        CHECK(yl_js_destroy(fresh));
      }
    }
  }
  printf("%d checks, %d contexts and runtimes created/freed, 0 failures\n",
         checks, total);
  return 0;
}
