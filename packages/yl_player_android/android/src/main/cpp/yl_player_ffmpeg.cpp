#include <jni.h>
#include <android/native_window_jni.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

namespace {

enum NativeKind { kUnknownKind = 0, kVideo = 1, kAudio = 2 };
enum NativeCodec {
  kUnknownCodec = 0, kH264 = 1, kHevc = 2, kAac = 3, kMp3 = 4,
  kAc3 = 5, kEac3 = 6, kDts = 7, kFlac = 8, kOpus = 9,
  kVorbis = 10, kVp9 = 11,
};

struct Renderer {
  ANativeWindow* window = nullptr;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  EGLSurface surface = EGL_NO_SURFACE;
  GLuint program = 0;
  GLuint textures[3] = {0, 0, 0};
  GLsizei texture_widths[3] = {0, 0, 0};
  GLsizei texture_heights[3] = {0, 0, 0};
  GLint position = -1;
  GLint tex_coord = -1;
  GLint y_sampler = -1;
  GLint u_sampler = -1;
  GLint v_sampler = -1;
  std::vector<uint8_t> planes[3];
};

struct DecodedVideoFrame {
  AVFrame* frame = nullptr;
  int64_t presentation_time_us = INT64_MIN;
};

struct Session {
  JavaVM* vm = nullptr;
  jobject source = nullptr;
  jmethodID read_method = nullptr;
  jmethodID seek_method = nullptr;
  jmethodID time_seek_method = nullptr;
  AVIOContext* io = nullptr;
  AVFormatContext* format = nullptr;
  std::atomic<bool> cancelled{false};
  std::mutex mutex;
  int hardware_video_stream = -1;
  AVBSFContext* video_bsf = nullptr;
  AVCodecContext* video_decoder = nullptr;
  int software_video_stream = -1;
  std::deque<DecodedVideoFrame> decoded_video_frames;
  Renderer renderer;
  AVCodecContext* audio_decoder = nullptr;
  SwrContext* resampler = nullptr;
  int software_audio_stream = -1;
  std::vector<uint8_t> packet_data;
  std::vector<uint8_t> pcm_data;
};

JNIEnv* env_for(Session* session) {
  JNIEnv* env = nullptr;
  if (session->vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    session->vm->AttachCurrentThread(&env, nullptr);
  }
  return env;
}

int avio_read(void* opaque, uint8_t* buffer, int size) {
  auto* session = static_cast<Session*>(opaque);
  if (session->cancelled.load()) return AVERROR_EXIT;
  JNIEnv* env = env_for(session);
  jobject target = env->NewDirectByteBuffer(buffer, size);
  jint count = env->CallIntMethod(session->source, session->read_method, target);
  env->DeleteLocalRef(target);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return AVERROR(EIO);
  }
  if (count == -2 || session->cancelled.load()) return AVERROR_EXIT;
  return count <= 0 ? AVERROR_EOF : count;
}

int64_t avio_seek(void* opaque, int64_t offset, int whence) {
  auto* session = static_cast<Session*>(opaque);
  if (session->cancelled.load()) return AVERROR_EXIT;
  JNIEnv* env = env_for(session);
  jlong result = env->CallLongMethod(session->source, session->seek_method,
                                     static_cast<jlong>(offset), static_cast<jint>(whence));
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return AVERROR(EIO);
  }
  if (result == -2 || session->cancelled.load()) return AVERROR_EXIT;
  return result < 0 ? AVERROR(ENOSYS) : result;
}

int interrupt(void* opaque) {
  return static_cast<Session*>(opaque)->cancelled.load() ? 1 : 0;
}

bool supported_input(const AVInputFormat* input) {
  if (!input || !input->name) return false;
  const std::string name(input->name);
  return name.find("mov") != std::string::npos || name.find("matroska") != std::string::npos ||
         name.find("flv") != std::string::npos || name.find("mpegts") != std::string::npos ||
         name == "aac" || name == "mp3" || name.find("ogg") != std::string::npos;
}

int codec_value(AVCodecID codec) {
  switch (codec) {
    case AV_CODEC_ID_H264: return kH264;
    case AV_CODEC_ID_HEVC: return kHevc;
    case AV_CODEC_ID_AAC: return kAac;
    case AV_CODEC_ID_MP3: return kMp3;
    case AV_CODEC_ID_AC3: return kAc3;
    case AV_CODEC_ID_EAC3: return kEac3;
    case AV_CODEC_ID_DTS: return kDts;
    case AV_CODEC_ID_FLAC: return kFlac;
    case AV_CODEC_ID_OPUS: return kOpus;
    case AV_CODEC_ID_VORBIS: return kVorbis;
    case AV_CODEC_ID_VP9: return kVp9;
    default: return kUnknownCodec;
  }
}

int kind_value(AVMediaType type) {
  if (type == AVMEDIA_TYPE_VIDEO) return kVideo;
  if (type == AVMEDIA_TYPE_AUDIO) return kAudio;
  return kUnknownKind;
}

int64_t timestamp_us(int64_t value, AVRational base) {
  return value == AV_NOPTS_VALUE ? INT64_MIN : av_rescale_q(value, base, AV_TIME_BASE_Q);
}

int64_t timestamp_from_us(int64_t value, AVRational base) {
  return value == INT64_MIN ? AV_NOPTS_VALUE : av_rescale_q(value, AV_TIME_BASE_Q, base);
}

GLuint compile_shader(GLenum kind, const char* source) {
  GLuint shader = glCreateShader(kind);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint ok = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) { glDeleteShader(shader); return 0; }
  return shader;
}

void destroy_renderer(Renderer* renderer) {
  if (renderer->display != EGL_NO_DISPLAY) {
    if (renderer->context != EGL_NO_CONTEXT && renderer->surface != EGL_NO_SURFACE) {
      eglMakeCurrent(renderer->display, renderer->surface, renderer->surface, renderer->context);
    }
    if (renderer->textures[0]) glDeleteTextures(3, renderer->textures);
    if (renderer->program) glDeleteProgram(renderer->program);
    eglMakeCurrent(renderer->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (renderer->surface != EGL_NO_SURFACE) eglDestroySurface(renderer->display, renderer->surface);
    if (renderer->context != EGL_NO_CONTEXT) eglDestroyContext(renderer->display, renderer->context);
    eglTerminate(renderer->display);
  }
  if (renderer->window) ANativeWindow_release(renderer->window);
  *renderer = Renderer{};
}

bool create_renderer(JNIEnv* env, jobject surface, Renderer* renderer) {
  destroy_renderer(renderer);
  renderer->window = ANativeWindow_fromSurface(env, surface);
  if (!renderer->window) return false;
  renderer->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (renderer->display == EGL_NO_DISPLAY || !eglInitialize(renderer->display, nullptr, nullptr)) return false;
  const EGLint config_attributes[] = {
      EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint count = 0;
  if (!eglChooseConfig(renderer->display, config_attributes, &config, 1, &count) || count != 1) return false;
  const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  renderer->context = eglCreateContext(renderer->display, config, EGL_NO_CONTEXT, context_attributes);
  renderer->surface = eglCreateWindowSurface(renderer->display, config, renderer->window, nullptr);
  if (renderer->context == EGL_NO_CONTEXT || renderer->surface == EGL_NO_SURFACE ||
      !eglMakeCurrent(renderer->display, renderer->surface, renderer->surface, renderer->context)) return false;

  static const char* vertex_source =
      "attribute vec2 position; attribute vec2 texCoord; varying vec2 uv;"
      "void main(){ gl_Position=vec4(position,0.0,1.0); uv=texCoord; }";
  static const char* fragment_source =
      "precision mediump float; varying vec2 uv; uniform sampler2D yTex;"
      "uniform sampler2D uTex; uniform sampler2D vTex;"
      "void main(){ float y=texture2D(yTex,uv).r; float u=texture2D(uTex,uv).r-0.5;"
      "float v=texture2D(vTex,uv).r-0.5; gl_FragColor=vec4(y+1.402*v,y-0.344136*u-0.714136*v,y+1.772*u,1.0); }";
  GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
  GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
  if (!vertex || !fragment) return false;
  renderer->program = glCreateProgram();
  glAttachShader(renderer->program, vertex);
  glAttachShader(renderer->program, fragment);
  glLinkProgram(renderer->program);
  glDeleteShader(vertex);
  glDeleteShader(fragment);
  GLint linked = GL_FALSE;
  glGetProgramiv(renderer->program, GL_LINK_STATUS, &linked);
  if (!linked) return false;
  renderer->position = glGetAttribLocation(renderer->program, "position");
  renderer->tex_coord = glGetAttribLocation(renderer->program, "texCoord");
  renderer->y_sampler = glGetUniformLocation(renderer->program, "yTex");
  renderer->u_sampler = glGetUniformLocation(renderer->program, "uTex");
  renderer->v_sampler = glGetUniformLocation(renderer->program, "vTex");
  glGenTextures(3, renderer->textures);
  for (GLuint texture : renderer->textures) {
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }
  return true;
}

void copy_plane_8(const uint8_t* source, int stride, int width, int height,
                  std::vector<uint8_t>* destination) {
  destination->resize(static_cast<size_t>(width) * height);
  for (int y = 0; y < height; ++y) {
    memcpy(destination->data() + static_cast<size_t>(y) * width,
           source + static_cast<ptrdiff_t>(y) * stride, width);
  }
}

void copy_plane_10(const uint8_t* source, int stride, int width, int height,
                   std::vector<uint8_t>* destination) {
  destination->resize(static_cast<size_t>(width) * height);
  for (int y = 0; y < height; ++y) {
    const auto* row = reinterpret_cast<const uint16_t*>(source + static_cast<ptrdiff_t>(y) * stride);
    for (int x = 0; x < width; ++x) (*destination)[static_cast<size_t>(y) * width + x] = row[x] >> 2;
  }
}

bool render_frame(Renderer* renderer, const AVFrame* frame) {
  if (renderer->display == EGL_NO_DISPLAY || !eglMakeCurrent(renderer->display, renderer->surface,
                                                               renderer->surface, renderer->context)) return false;
  const int chroma_width = (frame->width + 1) / 2;
  const int chroma_height = (frame->height + 1) / 2;
  if (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P) {
    copy_plane_8(frame->data[0], frame->linesize[0], frame->width, frame->height, &renderer->planes[0]);
    copy_plane_8(frame->data[1], frame->linesize[1], chroma_width, chroma_height, &renderer->planes[1]);
    copy_plane_8(frame->data[2], frame->linesize[2], chroma_width, chroma_height, &renderer->planes[2]);
  } else if (frame->format == AV_PIX_FMT_YUV420P10LE) {
    copy_plane_10(frame->data[0], frame->linesize[0], frame->width, frame->height, &renderer->planes[0]);
    copy_plane_10(frame->data[1], frame->linesize[1], chroma_width, chroma_height, &renderer->planes[1]);
    copy_plane_10(frame->data[2], frame->linesize[2], chroma_width, chroma_height, &renderer->planes[2]);
  } else if (frame->format == AV_PIX_FMT_NV12 || frame->format == AV_PIX_FMT_NV21) {
    copy_plane_8(frame->data[0], frame->linesize[0], frame->width, frame->height, &renderer->planes[0]);
    renderer->planes[1].resize(static_cast<size_t>(chroma_width) * chroma_height);
    renderer->planes[2].resize(static_cast<size_t>(chroma_width) * chroma_height);
    const bool nv21 = frame->format == AV_PIX_FMT_NV21;
    for (int y = 0; y < chroma_height; ++y) {
      const uint8_t* row = frame->data[1] + static_cast<ptrdiff_t>(y) * frame->linesize[1];
      for (int x = 0; x < chroma_width; ++x) {
        renderer->planes[nv21 ? 2 : 1][static_cast<size_t>(y) * chroma_width + x] = row[x * 2];
        renderer->planes[nv21 ? 1 : 2][static_cast<size_t>(y) * chroma_width + x] = row[x * 2 + 1];
      }
    }
  } else {
    return false;
  }
  static const GLfloat vertices[] = {-1, -1, 1, -1, -1, 1, 1, 1};
  static const GLfloat coordinates[] = {0, 1, 1, 1, 0, 0, 1, 0};
  glViewport(0, 0, ANativeWindow_getWidth(renderer->window), ANativeWindow_getHeight(renderer->window));
  glUseProgram(renderer->program);
  glVertexAttribPointer(renderer->position, 2, GL_FLOAT, GL_FALSE, 0, vertices);
  glEnableVertexAttribArray(renderer->position);
  glVertexAttribPointer(renderer->tex_coord, 2, GL_FLOAT, GL_FALSE, 0, coordinates);
  glEnableVertexAttribArray(renderer->tex_coord);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  const int widths[] = {frame->width, chroma_width, chroma_width};
  const int heights[] = {frame->height, chroma_height, chroma_height};
  const GLint samplers[] = {renderer->y_sampler, renderer->u_sampler, renderer->v_sampler};
  for (int i = 0; i < 3; ++i) {
    glActiveTexture(GL_TEXTURE0 + i);
    glBindTexture(GL_TEXTURE_2D, renderer->textures[i]);
    if (renderer->texture_widths[i] != widths[i] || renderer->texture_heights[i] != heights[i]) {
      glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, widths[i], heights[i], 0,
                   GL_LUMINANCE, GL_UNSIGNED_BYTE, nullptr);
      renderer->texture_widths[i] = widths[i];
      renderer->texture_heights[i] = heights[i];
    }
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, widths[i], heights[i],
                    GL_LUMINANCE, GL_UNSIGNED_BYTE, renderer->planes[i].data());
    glUniform1i(samplers[i], i);
  }
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  return glGetError() == GL_NO_ERROR && eglSwapBuffers(renderer->display, renderer->surface);
}

void clear_decoded_video_frames(Session* session) {
  for (auto& decoded : session->decoded_video_frames) av_frame_free(&decoded.frame);
  session->decoded_video_frames.clear();
}

void free_session(JNIEnv* env, Session* session) {
  if (!session) return;
  session->cancelled.store(true);
  av_bsf_free(&session->video_bsf);
  clear_decoded_video_frames(session);
  avcodec_free_context(&session->video_decoder);
  avcodec_free_context(&session->audio_decoder);
  swr_free(&session->resampler);
  destroy_renderer(&session->renderer);
  avformat_close_input(&session->format);
  if (session->io) avio_context_free(&session->io);
  if (session->source) env->DeleteGlobalRef(session->source);
  delete session;
}

AVCodecContext* create_decoder(Session* session, int stream_index) {
  if (stream_index < 0 || static_cast<unsigned>(stream_index) >= session->format->nb_streams) return nullptr;
  AVCodecParameters* parameters = session->format->streams[stream_index]->codecpar;
  const AVCodec* codec = avcodec_find_decoder(parameters->codec_id);
  if (!codec) return nullptr;
  AVCodecContext* decoder = avcodec_alloc_context3(codec);
  if (!decoder || avcodec_parameters_to_context(decoder, parameters) < 0 || avcodec_open2(decoder, codec, nullptr) < 0) {
    avcodec_free_context(&decoder);
    return nullptr;
  }
  decoder->pkt_timebase = session->format->streams[stream_index]->time_base;
  return decoder;
}

jlongArray receive_video_frames(JNIEnv* env, Session* session) {
  std::vector<jlong> presentation_times;
  while (true) {
    AVFrame* frame = av_frame_alloc();
    if (!frame) return nullptr;
    int result = avcodec_receive_frame(session->video_decoder, frame);
    if (result < 0) {
      av_frame_free(&frame);
      if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) return nullptr;
      break;
    }
    AVStream* stream = session->format->streams[session->software_video_stream];
    int64_t presentation_time_us = timestamp_us(frame->best_effort_timestamp, stream->time_base);
    session->decoded_video_frames.push_back({frame, presentation_time_us});
    presentation_times.push_back(presentation_time_us);
  }
  jlongArray result = env->NewLongArray(static_cast<jsize>(presentation_times.size()));
  if (result && !presentation_times.empty()) {
    env->SetLongArrayRegion(result, 0, static_cast<jsize>(presentation_times.size()),
                            presentation_times.data());
  }
  return result;
}

Session* from(jlong handle) { return reinterpret_cast<Session*>(handle); }

jbyteArray bytes(JNIEnv* env, const uint8_t* data, size_t size) {
  jbyteArray result = env->NewByteArray(static_cast<jsize>(size));
  if (result && size) env->SetByteArrayRegion(result, 0, static_cast<jsize>(size), reinterpret_cast<const jbyte*>(data));
  return result;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeOpen(JNIEnv* env, jobject, jobject source) {
  auto* session = new Session();
  env->GetJavaVM(&session->vm);
  session->source = env->NewGlobalRef(source);
  jclass source_class = env->GetObjectClass(source);
  session->read_method = env->GetMethodID(source_class, "read", "(Ljava/nio/ByteBuffer;)I");
  session->seek_method = env->GetMethodID(source_class, "seek", "(JI)J");
  session->time_seek_method = env->GetMethodID(source_class, "seekTime", "(J)J");
  env->DeleteLocalRef(source_class);
  if (!session->read_method || !session->seek_method || !session->time_seek_method) { free_session(env, session); return 0; }
  uint8_t* buffer = static_cast<uint8_t*>(av_malloc(64 * 1024));
  session->io = avio_alloc_context(buffer, 64 * 1024, 0, session, avio_read, nullptr, avio_seek);
  if (!session->io) { av_free(buffer); free_session(env, session); return 0; }
  const AVInputFormat* input = nullptr;
  if (av_probe_input_buffer2(session->io, &input, nullptr, nullptr, 0, 1024 * 1024) < 0 || !supported_input(input)) {
    free_session(env, session); return 0;
  }
  session->format = avformat_alloc_context();
  if (!session->format) { free_session(env, session); return 0; }
  session->format->pb = session->io;
  session->format->flags |= AVFMT_FLAG_CUSTOM_IO;
  session->format->interrupt_callback = {interrupt, session};
  if (avformat_open_input(&session->format, nullptr, input, nullptr) < 0 ||
      avformat_find_stream_info(session->format, nullptr) < 0) {
    free_session(env, session); return 0;
  }
  return reinterpret_cast<jlong>(session);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeStreamCount(JNIEnv*, jobject, jlong handle) {
  auto* session = from(handle);
  return session && session->format ? static_cast<jint>(session->format->nb_streams) : 0;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeDurationUs(JNIEnv*, jobject, jlong handle) {
  auto* session = from(handle);
  return !session || !session->format || session->format->duration == AV_NOPTS_VALUE ? -1 : session->format->duration;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeIsSeekable(JNIEnv*, jobject, jlong handle) {
  auto* session = from(handle);
  return session && session->io && (session->io->seekable & AVIO_SEEKABLE_NORMAL) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeStreamInfo(JNIEnv* env, jobject, jlong handle, jint index) {
  auto* session = from(handle);
  if (!session || index < 0 || static_cast<unsigned>(index) >= session->format->nb_streams) return nullptr;
  AVStream* stream = session->format->streams[index];
  AVCodecParameters* parameters = stream->codecpar;
  AVRational frame_rate = av_guess_frame_rate(session->format, stream, nullptr);
  jlong values[] = {
      kind_value(parameters->codec_type), codec_value(parameters->codec_id), parameters->width, parameters->height,
      frame_rate.den ? static_cast<jlong>(av_q2d(frame_rate) * 1000.0) : 0,
      parameters->profile, parameters->level, parameters->sample_rate, parameters->ch_layout.nb_channels,
      parameters->bit_rate, timestamp_us(stream->duration, stream->time_base)};
  jlongArray result = env->NewLongArray(11);
  env->SetLongArrayRegion(result, 0, 11, values);
  return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeStreamLanguage(JNIEnv* env, jobject, jlong handle, jint index) {
  auto* session = from(handle);
  if (!session || index < 0 || static_cast<unsigned>(index) >= session->format->nb_streams) return nullptr;
  const AVDictionaryEntry* language = av_dict_get(session->format->streams[index]->metadata, "language", nullptr, 0);
  return language && language->value ? env->NewStringUTF(language->value) : nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeStreamCodecConfig(JNIEnv* env, jobject, jlong handle, jint index) {
  auto* session = from(handle);
  if (!session || index < 0 || static_cast<unsigned>(index) >= session->format->nb_streams) return env->NewByteArray(0);
  AVCodecParameters* parameters = session->format->streams[index]->codecpar;
  return bytes(env, parameters->extradata, std::max(parameters->extradata_size, 0));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeConfigureHardwareVideo(JNIEnv*, jobject, jlong handle, jint index) {
  auto* session = from(handle);
  if (!session || index < 0 || static_cast<unsigned>(index) >= session->format->nb_streams) return JNI_FALSE;
  AVCodecParameters* parameters = session->format->streams[index]->codecpar;
  const char* filter_name = parameters->codec_id == AV_CODEC_ID_H264 ? "h264_mp4toannexb" :
                            parameters->codec_id == AV_CODEC_ID_HEVC ? "hevc_mp4toannexb" : nullptr;
  if (!filter_name) return JNI_FALSE;
  const AVBitStreamFilter* filter = av_bsf_get_by_name(filter_name);
  AVBSFContext* bsf = nullptr;
  if (!filter || av_bsf_alloc(filter, &bsf) < 0 || avcodec_parameters_copy(bsf->par_in, parameters) < 0) {
    av_bsf_free(&bsf); return JNI_FALSE;
  }
  bsf->time_base_in = session->format->streams[index]->time_base;
  if (av_bsf_init(bsf) < 0) { av_bsf_free(&bsf); return JNI_FALSE; }
  av_bsf_free(&session->video_bsf);
  session->video_bsf = bsf;
  session->hardware_video_stream = index;
  return JNI_TRUE;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeHardwareCodecConfig(
    JNIEnv* env, jobject, jlong handle) {
  auto* session = from(handle);
  if (!session || !session->video_bsf || !session->video_bsf->par_out) return env->NewByteArray(0);
  AVCodecParameters* parameters = session->video_bsf->par_out;
  return bytes(env, parameters->extradata, std::max(parameters->extradata_size, 0));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeConfigureSoftwareVideo(
    JNIEnv* env, jobject, jlong handle, jint index, jobject surface) {
  auto* session = from(handle);
  if (!session) return JNI_FALSE;
  AVCodecContext* decoder = create_decoder(session, index);
  if (!decoder || !create_renderer(env, surface, &session->renderer)) {
    avcodec_free_context(&decoder); destroy_renderer(&session->renderer); return JNI_FALSE;
  }
  avcodec_free_context(&session->video_decoder);
  clear_decoded_video_frames(session);
  session->video_decoder = decoder;
  session->software_video_stream = index;
  return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeConfigureSoftwareAudio(
    JNIEnv*, jobject, jlong handle, jint index) {
  auto* session = from(handle);
  if (!session) return JNI_FALSE;
  AVCodecContext* decoder = create_decoder(session, index);
  if (!decoder) return JNI_FALSE;
  AVChannelLayout output{};
  av_channel_layout_default(&output, std::min(std::max(decoder->ch_layout.nb_channels, 1), 2));
  SwrContext* resampler = nullptr;
  if (swr_alloc_set_opts2(&resampler, &output, AV_SAMPLE_FMT_S16, decoder->sample_rate,
                          &decoder->ch_layout, decoder->sample_fmt, decoder->sample_rate, 0, nullptr) < 0 ||
      swr_init(resampler) < 0) {
    av_channel_layout_uninit(&output); swr_free(&resampler); avcodec_free_context(&decoder); return JNI_FALSE;
  }
  av_channel_layout_uninit(&output);
  avcodec_free_context(&session->audio_decoder);
  swr_free(&session->resampler);
  session->audio_decoder = decoder;
  session->resampler = resampler;
  session->software_audio_stream = index;
  return JNI_TRUE;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeReadPacket(JNIEnv* env, jobject, jlong handle) {
  auto* session = from(handle);
  if (!session) return nullptr;
  std::lock_guard<std::mutex> guard(session->mutex);
  AVPacket* packet = av_packet_alloc();
  while (packet && !session->cancelled.load()) {
    int result = av_read_frame(session->format, packet);
    if (result < 0) {
      av_packet_free(&packet);
      if (result == AVERROR_EOF) return nullptr;
      jlong values[] = {-1, result, 0, 0, 0};
      jlongArray metadata = env->NewLongArray(5);
      env->SetLongArrayRegion(metadata, 0, 5, values);
      return metadata;
    }
    if (packet->stream_index == session->hardware_video_stream && session->video_bsf) {
      if (av_bsf_send_packet(session->video_bsf, packet) < 0) { av_packet_unref(packet); continue; }
      result = av_bsf_receive_packet(session->video_bsf, packet);
      if (result == AVERROR(EAGAIN)) { av_packet_unref(packet); continue; }
      if (result < 0) { av_packet_free(&packet); return nullptr; }
    }
    AVStream* stream = session->format->streams[packet->stream_index];
    session->packet_data.assign(packet->data, packet->data + packet->size);
    jlong values[] = {packet->stream_index, timestamp_us(packet->pts, stream->time_base),
                      timestamp_us(packet->dts, stream->time_base), timestamp_us(packet->duration, stream->time_base),
                      (packet->flags & AV_PKT_FLAG_KEY) ? 1 : 0};
    av_packet_free(&packet);
    jlongArray metadata = env->NewLongArray(5);
    env->SetLongArrayRegion(metadata, 0, 5, values);
    return metadata;
  }
  av_packet_free(&packet);
  return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeTakePacketData(JNIEnv* env, jobject, jlong handle) {
  auto* session = from(handle);
  if (!session) return env->NewByteArray(0);
  jbyteArray result = bytes(env, session->packet_data.data(), session->packet_data.size());
  session->packet_data.clear();
  return result;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeDecodeSoftwareVideo(
    JNIEnv* env, jobject, jlong handle, jbyteArray data, jlong pts_us, jlong dts_us) {
  auto* session = from(handle);
  if (!session || !session->video_decoder || session->software_video_stream < 0) return nullptr;
  const jsize size = env->GetArrayLength(data);
  AVPacket* packet = av_packet_alloc();
  if (!packet || av_new_packet(packet, size) < 0) { av_packet_free(&packet); return nullptr; }
  env->GetByteArrayRegion(data, 0, size, reinterpret_cast<jbyte*>(packet->data));
  AVStream* stream = session->format->streams[session->software_video_stream];
  packet->pts = timestamp_from_us(pts_us, stream->time_base);
  packet->dts = timestamp_from_us(dts_us, stream->time_base);
  int result = avcodec_send_packet(session->video_decoder, packet);
  av_packet_free(&packet);
  if (result < 0) return nullptr;
  return receive_video_frames(env, session);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeFinishSoftwareVideo(
    JNIEnv* env, jobject, jlong handle) {
  auto* session = from(handle);
  if (!session || !session->video_decoder) return nullptr;
  int result = avcodec_send_packet(session->video_decoder, nullptr);
  if (result < 0 && result != AVERROR_EOF) return nullptr;
  return receive_video_frames(env, session);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeRenderSoftwareVideoFrame(
    JNIEnv*, jobject, jlong handle) {
  auto* session = from(handle);
  if (!session || session->decoded_video_frames.empty()) return JNI_FALSE;
  DecodedVideoFrame decoded = session->decoded_video_frames.front();
  session->decoded_video_frames.pop_front();
  const bool rendered = render_frame(&session->renderer, decoded.frame);
  av_frame_free(&decoded.frame);
  return rendered ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeDecodeSoftwareAudio(
    JNIEnv* env, jobject, jlong handle, jbyteArray data, jlong pts) {
  auto* session = from(handle);
  if (!session || !session->audio_decoder || !session->resampler) return nullptr;
  const jsize size = env->GetArrayLength(data);
  AVPacket* packet = av_packet_alloc();
  if (!packet || av_new_packet(packet, size) < 0) { av_packet_free(&packet); return nullptr; }
  env->GetByteArrayRegion(data, 0, size, reinterpret_cast<jbyte*>(packet->data));
  packet->pts = AV_NOPTS_VALUE;
  int result = avcodec_send_packet(session->audio_decoder, packet);
  av_packet_free(&packet);
  if (result < 0 && result != AVERROR(EAGAIN)) return nullptr;
  AVFrame* frame = av_frame_alloc();
  session->pcm_data.clear();
  int64_t first_pts = pts;
  const int channels = std::min(std::max(session->audio_decoder->ch_layout.nb_channels, 1), 2);
  while (frame && avcodec_receive_frame(session->audio_decoder, frame) >= 0) {
    const int output_samples = swr_get_out_samples(session->resampler, frame->nb_samples);
    const size_t old_size = session->pcm_data.size();
    session->pcm_data.resize(old_size + static_cast<size_t>(output_samples) * channels * sizeof(int16_t));
    uint8_t* output[] = {session->pcm_data.data() + old_size};
    int converted = swr_convert(session->resampler, output, output_samples,
                                const_cast<const uint8_t**>(frame->extended_data), frame->nb_samples);
    if (converted < 0) { session->pcm_data.clear(); break; }
    session->pcm_data.resize(old_size + static_cast<size_t>(converted) * channels * sizeof(int16_t));
    if (first_pts == INT64_MIN && frame->best_effort_timestamp != AV_NOPTS_VALUE) {
      first_pts = av_rescale_q(frame->best_effort_timestamp, session->audio_decoder->time_base, AV_TIME_BASE_Q);
    }
    av_frame_unref(frame);
  }
  av_frame_free(&frame);
  if (session->pcm_data.empty()) return nullptr;
  jlong values[] = {session->audio_decoder->sample_rate, channels, first_pts};
  jlongArray metadata = env->NewLongArray(3);
  env->SetLongArrayRegion(metadata, 0, 3, values);
  return metadata;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeTakePcmData(JNIEnv* env, jobject, jlong handle) {
  auto* session = from(handle);
  if (!session) return env->NewByteArray(0);
  jbyteArray result = bytes(env, session->pcm_data.data(), session->pcm_data.size());
  session->pcm_data.clear();
  return result;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeSeek(JNIEnv*, jobject, jlong handle, jlong position_us) {
  auto* session = from(handle);
  if (!session || position_us < 0) return JNI_FALSE;
  std::lock_guard<std::mutex> guard(session->mutex);
  JNIEnv* env = env_for(session);
  jlong callback_position = env->CallLongMethod(session->source, session->time_seek_method, position_us);
  if (env->ExceptionCheck()) { env->ExceptionClear(); callback_position = -3; }
  if (callback_position >= 0) {
    session->io->buf_ptr = session->io->buf_end;
    session->io->eof_reached = 0;
    session->io->error = 0;
    avformat_flush(session->format);
    if (session->video_bsf) av_bsf_flush(session->video_bsf);
    clear_decoded_video_frames(session);
    if (session->video_decoder) avcodec_flush_buffers(session->video_decoder);
    if (session->audio_decoder) avcodec_flush_buffers(session->audio_decoder);
    return JNI_TRUE;
  }
  int result = avformat_seek_file(session->format, -1, INT64_MIN, position_us, INT64_MAX, AVSEEK_FLAG_BACKWARD);
  if (result >= 0) {
    avformat_flush(session->format);
    if (session->video_bsf) av_bsf_flush(session->video_bsf);
    clear_decoded_video_frames(session);
    if (session->video_decoder) avcodec_flush_buffers(session->video_decoder);
    if (session->audio_decoder) avcodec_flush_buffers(session->audio_decoder);
  }
  return result >= 0 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeFlush(JNIEnv*, jobject, jlong handle) {
  auto* session = from(handle);
  if (!session) return;
  if (session->video_bsf) av_bsf_flush(session->video_bsf);
  clear_decoded_video_frames(session);
  if (session->video_decoder) avcodec_flush_buffers(session->video_decoder);
  if (session->audio_decoder) avcodec_flush_buffers(session->audio_decoder);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_nativeClose(JNIEnv* env, jobject, jlong handle) {
  free_session(env, from(handle));
}
