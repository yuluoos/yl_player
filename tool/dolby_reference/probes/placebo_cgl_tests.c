/* Research-only macOS context adapter for the pinned upstream GPU tests. */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <stdio.h>
#include <libplacebo/opengl.h>
#include "gpu_tests.h"

static pl_voidfunc_t get_proc(const char *name)
{
    return (pl_voidfunc_t) dlsym(RTLD_DEFAULT, name);
}

int main(void)
{
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute) kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, (CGLPixelFormatAttribute) 0
    };
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count = 0;
    CGLError error = CGLChoosePixelFormat(attributes, &format, &count);
    if (error != kCGLNoError || !format || count == 0) {
        if (format) CGLDestroyPixelFormat(format);
        fprintf(stderr, "SKIP: accelerated CGL pixel format unavailable (%d)\n", error);
        return 77;
    }
    error = CGLCreateContext(format, NULL, &context);
    CGLDestroyPixelFormat(format);
    if (error != kCGLNoError || !context) {
        fprintf(stderr, "SKIP: CGL context unavailable (%d)\n", error);
        return 77;
    }
    if (CGLSetCurrentContext(context) != kCGLNoError) {
        CGLDestroyContext(context);
        fprintf(stderr, "SKIP: CGL context binding failed\n");
        return 77;
    }
    printf("CGL vendor=%s renderer=%s version=%s\n",
           glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));
    pl_log log = pl_test_logger();
    pl_opengl gl = pl_opengl_create(log, pl_opengl_params(
        .get_proc_addr = get_proc, .allow_software = false, .debug = true
    ));
    int result = 1;
    if (gl) {
        pl_gpu gpu = gl->gpu;
        pl_fmt floating = pl_find_fmt(gpu, PL_FMT_FLOAT, 4, 16, 32,
            PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_BLITTABLE | PL_FMT_CAP_LINEAR);
        pl_fmt integer = pl_find_fmt(gpu, PL_FMT_UNORM, 4, 16, 16,
            PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_HOST_READABLE);
        // These upstream test groups otherwise return early without failing.
        if (gpu->glsl.version < 410 || !floating || !integer ||
            integer->component_depth[0] != 16) {
            fprintf(stderr, "SKIP: required shader/readback test capabilities absent\n");
            result = 77;
        } else {
            printf("Required test formats: float=%s unorm=%s GLSL=%d\n",
                   floating->name, integer->name, gpu->glsl.version);
            gpu_shader_tests(gpu);
            gpu_interop_tests(gpu);
            pl_gpu_finish(gpu);
            result = pl_gpu_is_failed(gpu) ? 1 : 0;
            if (!result) puts("PASS: pinned upstream GPU tests returned on accelerated CGL; capability-gated branches remain conditional");
        }
        pl_opengl_destroy(&gl);
    } else {
        fprintf(stderr, "FAIL: libplacebo rejected the current CGL context\n");
    }
    pl_log_destroy(&log);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    return result;
}
