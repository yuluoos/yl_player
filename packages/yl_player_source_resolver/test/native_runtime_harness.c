#include "../src/yl_script_runtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int failures, checks;
#define CHECK(x)                                                               \
  do {                                                                         \
    checks++;                                                                  \
    if (!(x)) {                                                                \
      fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x);                     \
      failures++;                                                              \
    }                                                                          \
  } while (0)
static yl_js_job *start(const char *s, unsigned ms) {
  return yl_js_start(s, strlen(s), "x=1&x=2", 7, ms, 8 * 1024 * 1024,
                     256 * 1024);
}
static int finish(yl_js_job *j) {
  int s = 0;
  for (int n = 0; n < 5000 && !(s = yl_js_status(j)); n++)
    usleep(1000);
  return s;
}
static void expected(const char *s, int status) {
  yl_js_job *j = start(s, 100);
  CHECK(j);
  CHECK(finish(j) == status);
  CHECK(yl_js_destroy(j));
}
int main(void) {
  yl_js_job *j = start("function main(p){return "
                       "JSON.stringify({url:'https://example.invalid/'+p})}",
                       1000);
  CHECK(j);
  CHECK(finish(j) == 1);
  char *out = yl_js_result(j);
  CHECK(out && strstr(out, "example.invalid/x=1&x=2"));
  yl_js_free(out);
  CHECK(yl_js_destroy(j));
  expected("function main(){return {toJSON(){return undefined}}}", 8);
  expected("async function main(){function f(){return f()+1}return f()}", 6);
  expected("function main(){return Atomics.wait(new Int32Array(new "
           "SharedArrayBuffer(4)),0,0)}",
           6);
  expected("function main(){return {url:typeof std+typeof os+typeof require}}",
           1);
  expected("function main(){return {url:parseItems('a=%ZZ')}}", 6);
  expected("function main(){return mytv.get('x'.repeat(70000))}", 4);
  expected("function main(){throw new InternalError('SECRET')}", 6);
  expected("function main(){function f(){return f()+1}try{f()}catch(e){}return "
           "{url:'ok'}}",
           1);
  expected("function main(){function f(){return "
           "f()+1}while(true){try{f()}catch(e){}}}",
           2);
  expected("while(true){}", 2);
  j = start("function main(){while(true){}}", 30000);
  usleep(20000);
  CHECK(yl_js_status(j) == 0);
  CHECK(!yl_js_destroy(j));
  yl_js_cancel(j);
  CHECK(finish(j) == 3);
  CHECK(yl_js_destroy(j));
  expected(
      "function main(){let a=[];while(true)a.push(new Array(10000).fill(1));}",
      4);
  expected("function main(){function f(){return f()+1}return f()}", 6);
  expected("function main(){return /^(a+)+$/.test('a'.repeat(200)+'!')}", 2);
  expected("function main( {", 5);
  expected("function main(){throw new Error('SECRET-password')} ", 6);
  expected("function main(){return mytv.unsupported('SECRET')}", 7);
  expected("function main(){return new Promise(()=>{})}", 8);
  expected("async function main(){await Promise.resolve();return "
           "{url:'https://example.invalid'}}",
           1);
  expected("function main(){return 'x'.repeat(70000)}", 4);
  expected(
      "function main(){return {url:parseItems('a=b=c&x=one+two&x=three').a}}",
      1);
  j = start("function main(){return "
            "{url:mytv.get('https://example.invalid',{'X':'y'})}}",
            1000);
  char *request = NULL;
  for (int n = 0; n < 1000 && !request; n++) {
    request = yl_js_take_request(j);
    usleep(1000);
  }
  CHECK(request && strstr(request, "\"method\":\"get\"") &&
        strstr(request, "example.invalid"));
  yl_js_free(request);
  CHECK(!yl_js_take_request(j));
  CHECK(yl_js_reply(j, "\"https://example.invalid/media\"", 31, 0));
  CHECK(!yl_js_reply(j, "null", 4, 0));
  CHECK(finish(j) == 1);
  CHECK(yl_js_destroy(j));
  j = start("function main(){return mytv.get('https://example.invalid')}",
            30000);
  request = NULL;
  for (int n = 0; n < 1000 && !request; n++) {
    request = yl_js_take_request(j);
    usleep(1000);
  }
  CHECK(request);
  yl_js_free(request);
  yl_js_cancel(j);
  CHECK(finish(j) == 3);
  CHECK(yl_js_destroy(j));
  j = start("function "
            "main(){try{mytv.get('https://example.invalid')}catch(e){}return "
            "{url:'fake'}}",
            1000);
  request = NULL;
  for (int n = 0; n < 1000 && !request; n++) {
    request = yl_js_take_request(j);
    usleep(1000);
  }
  CHECK(request);
  yl_js_free(request);
  CHECK(yl_js_reply(j, NULL, 0, 1));
  CHECK(finish(j) == 9);
  CHECK(yl_js_destroy(j));
  yl_js_job *jobs[4];
  for (int n = 0; n < 4; n++) {
    jobs[n] = start("while(true){}", 30000);
    CHECK(jobs[n]);
  }
  CHECK(!start("while(true){}", 30000));
  for (int n = 0; n < 4; n++) {
    yl_js_cancel(jobs[n]);
    CHECK(finish(jobs[n]) == 3);
    CHECK(yl_js_destroy(jobs[n]));
  }
  for (int n = 0; n < 20; n++)
    expected("function main(){return {url:'ok'}}", 1);
  CHECK(!yl_js_start("", 0, "", 0, 30001, 8 * 1024 * 1024, 256 * 1024));
  CHECK(!yl_js_start("", 524289, "", 0, 100, 8 * 1024 * 1024, 256 * 1024));
  CHECK(!yl_js_start("", 0, "", 8193, 100, 8 * 1024 * 1024, 256 * 1024));
  j = start(
      "function main(){for(let "
      "i=0;i<9;i++)mytv.get('https://example.invalid');return {url:'fake'}}",
      1000);
  for (int n = 0; n < 8; n++) {
    request = NULL;
    for (int t = 0; t < 1000 && !request; t++) {
      request = yl_js_take_request(j);
      usleep(1000);
    }
    CHECK(request);
    yl_js_free(request);
    CHECK(yl_js_reply(j, "null", 4, 0));
  }
  CHECK(finish(j) == 4);
  CHECK(yl_js_destroy(j));
  j = start("function main(){return mytv.get('https://example.invalid')}",
            1000);
  request = NULL;
  for (int n = 0; n < 1000 && !request; n++) {
    request = yl_js_take_request(j);
    usleep(1000);
  }
  CHECK(request);
  yl_js_free(request);
  CHECK(yl_js_reply(j, "", 1048577, 0));
  CHECK(finish(j) == 4);
  CHECK(yl_js_destroy(j));
  j = start("function main(){return mytv.get('https://example.invalid')}",
            1000);
  request = NULL;
  for (int n = 0; n < 1000 && !request; n++) {
    request = yl_js_take_request(j);
    usleep(1000);
  }
  CHECK(request);
  yl_js_free(request);
  CHECK(yl_js_reply(j, "not-json", 8, 0));
  CHECK(finish(j) == 9);
  CHECK(yl_js_destroy(j));
  printf("%d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
