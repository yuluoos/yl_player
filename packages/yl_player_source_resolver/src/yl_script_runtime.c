#include "cryptojs/crypto_js.inc"
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "yl_script_runtime.h"
#include "quickjs/quickjs.h"
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define KIB ((size_t)1024)
#define MIB (1024 * KIB)
struct yl_js_job {
  pthread_t thread;
  pthread_mutex_t mutex;
  pthread_cond_t condition;
  atomic_int status, cancelled, failure;
  uint64_t deadline;
  size_t heap, stack, source_len, parameter_len;
  char *source, *parameter, *result, *request, *reply;
  size_t reply_len, response_total;
  unsigned requests;
  int waiting, taken, replied;
};
static atomic_uint active_jobs;
static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static char *copy_bytes(const char *s, size_t n) {
  char *p = malloc(n + 1);
  if (p) {
    if (n)
      memcpy(p, s, n);
    p[n] = 0;
  }
  return p;
}
static void fail(yl_js_job *j, int code) {
  int zero = 0;
  atomic_compare_exchange_strong(&j->failure, &zero, code);
}
static int stop_reason(yl_js_job *j) {
  if (atomic_load(&j->cancelled))
    return 3;
  if (now_ns() >= j->deadline)
    return 2;
  return atomic_load(&j->failure);
}
static int interrupt(JSRuntime *rt, void *opaque) {
  (void)rt;
  return stop_reason(opaque) != 0;
}
/* A prefix keeps accounting portable and captures allocation failure without
 * examining or serializing an untrusted JavaScript exception. */
typedef union allocation_header {
  size_t size;
  max_align_t alignment;
} allocation_header;
static size_t allocation_size(const void *p) {
  return p ? ((const allocation_header *)p)[-1].size : 0;
}
static void *allocate(JSMallocState *s, size_t n) {
  yl_js_job *j = s->opaque;
  if (n > j->heap || sizeof(allocation_header) > j->heap - n ||
      s->malloc_size > j->heap - n - sizeof(allocation_header)) {
    fail(j, 4);
    return NULL;
  }
  allocation_header *p = malloc(n + sizeof(*p));
  if (!p) {
    fail(j, 4);
    return NULL;
  }
  p->size = n;
  s->malloc_count++;
  s->malloc_size += n + sizeof(*p);
  return p + 1;
}
static void deallocate(JSMallocState *s, void *p) {
  if (!p)
    return;
  allocation_header *h = (allocation_header *)p - 1;
  s->malloc_size -= h->size + sizeof(*h);
  s->malloc_count--;
  free(h);
}
static void *reallocate(JSMallocState *s, void *p, size_t n) {
  if (!p)
    return allocate(s, n);
  if (!n) {
    deallocate(s, p);
    return NULL;
  }
  yl_js_job *j = s->opaque;
  allocation_header *h = (allocation_header *)p - 1;
  size_t old = h->size;
  if (n > j->heap || s->malloc_size - old > j->heap - n) {
    fail(j, 4);
    return NULL;
  }
  h = realloc(h, n + sizeof(*h));
  if (!h) {
    fail(j, 4);
    return NULL;
  }
  h->size = n;
  s->malloc_size = s->malloc_size - old + n;
  return h + 1;
}
static const JSMallocFunctions allocator = {allocate, deallocate, reallocate,
                                            allocation_size};

/* The host wait always uses a monotonic/relative clock. Cancellation wakes it
 * immediately; the bounded tick also checks the shared native deadline. */
static void wait_tick(yl_js_job *j) {
#ifdef __APPLE__
  struct timespec relative = {0, 10000000};
  pthread_cond_timedwait_relative_np(&j->condition, &j->mutex, &relative);
#else
  uint64_t until = now_ns() + 10000000;
  struct timespec absolute = {(time_t)(until / 1000000000ULL),
                              (long)(until % 1000000000ULL)};
  pthread_cond_timedwait(&j->condition, &j->mutex, &absolute);
#endif
}
static JSValue host_call(JSContext *ctx, JSValueConst receiver, int argc,
                         JSValueConst *argv, int magic) {
  (void)receiver;
  yl_js_job *j = JS_GetContextOpaque(ctx);
  if (magic == 4)
    return JS_UNDEFINED; /* log intentionally never emits payloads */
  if (magic < 0) {
    fail(j, 7);
    return JS_ThrowTypeError(ctx, "unsupported host API");
  }
  if (stop_reason(j))
    return JS_ThrowInternalError(ctx, "host stopped");
  if (++j->requests > 8) {
    fail(j, 4);
    return JS_ThrowInternalError(ctx, "host limit");
  }
  static const char *methods[] = {"get", "fetch", "post", "request"};
  JSValue obj = JS_NewObject(ctx), args = JS_NewArray(ctx);
  for (int i = 0; i < argc; i++)
    JS_SetPropertyUint32(ctx, args, (uint32_t)i, JS_DupValue(ctx, argv[i]));
  JS_SetPropertyStr(ctx, obj, "method", JS_NewString(ctx, methods[magic]));
  JS_SetPropertyStr(ctx, obj, "args", args);
  JSValue encoded = JS_JSONStringify(ctx, obj, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(ctx, obj);
  size_t length = 0;
  const char *text =
      JS_IsException(encoded) ? NULL : JS_ToCStringLen(ctx, &length, encoded);
  if (!text || length > 64 * KIB) {
    if (length > 64 * KIB)
      fail(j, 4);
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, encoded);
    return JS_EXCEPTION;
  }
  char *request = copy_bytes(text, length);
  JS_FreeCString(ctx, text);
  JS_FreeValue(ctx, encoded);
  if (!request) {
    fail(j, 4);
    return JS_ThrowOutOfMemory(ctx);
  }
  pthread_mutex_lock(&j->mutex);
  j->request = request;
  j->waiting = 1;
  j->taken = 0;
  j->replied = 0;
  while (!j->replied && !stop_reason(j))
    wait_tick(j);
  char *reply = j->reply;
  size_t reply_len = j->reply_len;
  j->reply = NULL;
  j->reply_len = 0;
  j->waiting = 0;
  free(j->request);
  j->request = NULL;
  pthread_mutex_unlock(&j->mutex);
  if (stop_reason(j)) {
    free(reply);
    return JS_ThrowInternalError(ctx, "host stopped");
  }
  JSValue value = JS_ParseJSON(ctx, reply, reply_len, "<host>");
  free(reply);
  if (JS_IsException(value))
    fail(j, 9);
  return value;
}
static const char prelude[] =
    "(()=>{const api=Object.create(null);"
    "for(const n of "
    "['get','fetch','post','request','log']){api[n]=globalThis['__yl_'+n];"
    "delete globalThis['__yl_'+n]}"
    "const missing=globalThis.__yl_missing;delete globalThis.__yl_missing;"
    "Object.freeze(api);globalThis.mytv=new Proxy(api,{get:(o,k)=>k in "
    "o?o[k]:missing()});"
    "globalThis.parseItems=function(query){const out=Object.create(null);"
    "if(!query)return out;for(const pair of "
    "String(query).split('&')){if(!pair)continue;"
    "const i=pair.indexOf('=');const k=i<0?pair:pair.slice(0,i);const "
    "v=i<0?'':pair.slice(i+1);"
    "out[decodeURIComponent(k.replace(/\\+/g,' "
    "'))]=decodeURIComponent(v.replace(/\\+/g,' '));}return out;};})();";
static int exception_status(JSContext *ctx, yl_js_job *j, int fallback) {
  int reason = stop_reason(j);
  JSValue ex = JS_GetException(ctx);
  /* Exception objects are untrusted. No constructor, message or stack is
   * read: only native control-plane latches identify a resource failure. */
  JS_FreeValue(ctx, ex);
  return reason ? reason : fallback;
}
static void *run_job(void *opaque) {
  yl_js_job *j = opaque;
  int status = 4;
  JSRuntime *rt = JS_NewRuntime2(&allocator, j);
  JSContext *ctx = NULL;
  JSValue value = JS_UNDEFINED, global = JS_UNDEFINED, main = JS_UNDEFINED;
  if (!rt)
    goto done;
  JS_SetMemoryLimit(rt, j->heap);
  JS_SetMaxStackSize(rt, j->stack);
  JS_SetInterruptHandler(rt, interrupt, j);
  JS_SetCanBlock(rt,
                 0); /* Atomics.wait must never escape native interruption. */
  ctx = JS_NewContext(rt);
  if (!ctx)
    goto done;
  JS_SetContextOpaque(ctx, j);
  global = JS_GetGlobalObject(ctx);
  const char *names[] = {"__yl_get",     "__yl_fetch", "__yl_post",
                         "__yl_request", "__yl_log",   "__yl_missing"};
  for (int i = 0; i < 6; i++)
    JS_SetPropertyStr(ctx, global, names[i],
                      JS_NewCFunctionMagic(ctx, host_call, names[i], 0,
                                           JS_CFUNC_generic_magic,
                                           i == 5 ? -1 : i));
  value = JS_Eval(ctx, prelude, sizeof(prelude) - 1, "<prelude>",
                  JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) {
    status = exception_status(ctx, j, 6);
    goto done;
  }
  JS_FreeValue(ctx, value);
  value = JS_Eval(ctx, (const char *)crypto_js, sizeof(crypto_js) - 1,
                  "<cryptojs>", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) {
    status = exception_status(ctx, j, 6);
    goto done;
  }
  JS_FreeValue(ctx, value);
  value = JS_Eval(ctx, j->source, j->source_len, "<script>",
                  JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(value)) {
    status = exception_status(ctx, j, 5);
    goto done;
  }
  value = JS_EvalFunction(ctx, value);
  if (JS_IsException(value)) {
    status = exception_status(ctx, j, 6);
    goto done;
  }
  JS_FreeValue(ctx, value);
  value = JS_UNDEFINED;
  main = JS_GetPropertyStr(ctx, global, "main");
  if (!JS_IsFunction(ctx, main)) {
    status = 8;
    goto done;
  }
  JSValue parameter = JS_NewStringLen(ctx, j->parameter, j->parameter_len);
  value = JS_Call(ctx, main, JS_UNDEFINED, 1, &parameter);
  JS_FreeValue(ctx, parameter);
  if (JS_IsException(value)) {
    status = exception_status(ctx, j, 6);
    goto done;
  }
  for (;;) {
    int state = JS_PromiseState(ctx, value);
    if (state < 0)
      break;
    if (state == JS_PROMISE_FULFILLED) {
      JSValue result = JS_PromiseResult(ctx, value);
      JS_FreeValue(ctx, value);
      value = result;
      continue;
    }
    if (state == JS_PROMISE_REJECTED) {
      JS_Throw(ctx, JS_PromiseResult(ctx, value));
      status = exception_status(ctx, j, 6);
      goto done;
    }
    if (stop_reason(j)) {
      status = stop_reason(j);
      goto done;
    }
    JSContext *job_ctx = NULL;
    int executed = JS_ExecutePendingJob(rt, &job_ctx);
    if (executed < 0) {
      status = exception_status(job_ctx, j, 6);
      goto done;
    }
    if (!executed) {
      status = 8;
      goto done;
    }
  }
  if (!JS_IsString(value) &&
      (!JS_IsObject(value) || JS_IsFunction(ctx, value))) {
    status = 8;
    goto done;
  }
  JSValue encoded = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(ctx, value);
  value = encoded;
  if (JS_IsException(value)) {
    status = exception_status(ctx, j, 8);
    goto done;
  }
  if (!JS_IsString(value)) {
    status = 8;
    goto done;
  }
  size_t length = 0;
  const char *result = JS_ToCStringLen(ctx, &length, value);
  if (!result) {
    status = exception_status(ctx, j, 8);
    goto done;
  }
  if (length > 64 * KIB)
    status = 4;
  else {
    j->result = copy_bytes(result, length);
    status = j->result ? 1 : 4;
  }
  JS_FreeCString(ctx, result);
done:
  if (ctx) {
    JS_FreeValue(ctx, value);
    JS_FreeValue(ctx, main);
    JS_FreeValue(ctx, global);
    JS_FreeContext(ctx);
  }
  if (rt)
    JS_FreeRuntime(rt);
  free(j->source);
  j->source = NULL;
  free(j->parameter);
  j->parameter = NULL;
  int reason = stop_reason(j);
  if (reason)
    status = reason;
  /* Release admission only after the complete VM is gone. The opaque job
   * remains caller-owned; destroy joins the worker before reclaiming it. */
  atomic_fetch_sub(&active_jobs, 1);
  atomic_store(&j->status, status);
  return NULL;
}
yl_js_job *yl_js_start(const char *source, size_t source_len,
                       const char *parameter, size_t parameter_len,
                       uint32_t timeout_ms, size_t heap, size_t stack) {
  if (!source || !parameter || source_len > 512 * KIB ||
      parameter_len > 8 * KIB || !timeout_ms || timeout_ms > 30000 ||
      heap < 8 * MIB || heap > 64 * MIB || stack < 256 * KIB || stack > MIB)
    return NULL;
  unsigned count = atomic_load(&active_jobs);
  do {
    if (count >= 4)
      return NULL;
  } while (!atomic_compare_exchange_weak(&active_jobs, &count, count + 1));
  yl_js_job *j = calloc(1, sizeof(*j));
  if (!j) {
    atomic_fetch_sub(&active_jobs, 1);
    return NULL;
  }
  atomic_init(&j->status, 0);
  atomic_init(&j->cancelled, 0);
  atomic_init(&j->failure, 0);
  j->source = copy_bytes(source, source_len);
  j->parameter = copy_bytes(parameter, parameter_len);
  j->source_len = source_len;
  j->parameter_len = parameter_len;
  j->heap = heap;
  j->stack = stack;
  j->deadline = now_ns() + (uint64_t)timeout_ms * 1000000;
  if (!j->source || !j->parameter)
    goto failed;
  if (pthread_mutex_init(&j->mutex, NULL))
    goto failed;
  pthread_condattr_t attr;
  pthread_condattr_init(&attr);
#ifndef __APPLE__
  pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
#endif
  int cond_error = pthread_cond_init(&j->condition, &attr);
  pthread_condattr_destroy(&attr);
  if (cond_error) {
    pthread_mutex_destroy(&j->mutex);
    goto failed;
  }
  pthread_attr_t thread_attr;
  pthread_attr_init(&thread_attr);
  /* QuickJS bounds its own stack below a larger native thread stack. */
  pthread_attr_setstacksize(&thread_attr, 2 * MIB);
  int thread_error = pthread_create(&j->thread, &thread_attr, run_job, j);
  pthread_attr_destroy(&thread_attr);
  if (!thread_error)
    return j;
  pthread_cond_destroy(&j->condition);
  pthread_mutex_destroy(&j->mutex);
failed:
  free(j->source);
  free(j->parameter);
  free(j);
  atomic_fetch_sub(&active_jobs, 1);
  return NULL;
}
int yl_js_status(yl_js_job *j) { return j ? atomic_load(&j->status) : 4; }
char *yl_js_take_request(yl_js_job *j) {
  if (!j)
    return NULL;
  pthread_mutex_lock(&j->mutex);
  char *result = NULL;
  if (j->waiting && !j->taken && !stop_reason(j)) {
    result = copy_bytes(j->request, strlen(j->request));
    if (result)
      j->taken = 1;
    else {
      fail(j, 4);
      pthread_cond_signal(&j->condition);
    }
  }
  pthread_mutex_unlock(&j->mutex);
  return result;
}
int yl_js_reply(yl_js_job *j, const char *json, size_t len, int error_code) {
  if (!j)
    return 0;
  pthread_mutex_lock(&j->mutex);
  int accepted = 0;
  if (j->waiting && j->taken && !j->replied && !stop_reason(j)) {
    accepted = 1;
    if (error_code)
      fail(j, 9);
    else if (!json || len > MIB || j->response_total > 4 * MIB - len)
      fail(j, 4);
    else {
      j->reply = copy_bytes(json, len);
      j->reply_len = len;
      j->response_total += len;
      if (!j->reply)
        fail(j, 4);
    }
    j->replied = 1;
    pthread_cond_signal(&j->condition);
  }
  pthread_mutex_unlock(&j->mutex);
  return accepted;
}
char *yl_js_result(yl_js_job *j) {
  return j && atomic_load(&j->status) == 1 && j->result
             ? copy_bytes(j->result, strlen(j->result))
             : NULL;
}
void yl_js_cancel(yl_js_job *j) {
  if (!j)
    return;
  atomic_store(&j->cancelled, 1);
  pthread_mutex_lock(&j->mutex);
  pthread_cond_signal(&j->condition);
  pthread_mutex_unlock(&j->mutex);
}
int yl_js_destroy(yl_js_job *j) {
  if (!j || !atomic_load(&j->status))
    return 0;
  pthread_join(j->thread, NULL);
  pthread_cond_destroy(&j->condition);
  pthread_mutex_destroy(&j->mutex);
  free(j->result);
  free(j->request);
  free(j->reply);
  free(j);
  return 1;
}
void yl_js_free(void *buffer) { free(buffer); }
