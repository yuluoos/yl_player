// Internal JNI ownership adapter. Included inside the bridge namespace.
// A frame's AVBuffer owns its receipt and the Java budget independently of Session.
struct SoftwareJniEnv {
  JavaVM* vm;
  JNIEnv* env = nullptr;
  bool attached = false;
  explicit SoftwareJniEnv(JavaVM* value) : vm(value) {
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK)
      attached = vm->AttachCurrentThread(&env, nullptr) == JNI_OK;
  }
  ~SoftwareJniEnv() { if (attached) vm->DetachCurrentThread(); }
};
struct SoftwareAccounting {
  JavaVM* vm;
  jobject budget;
  jmethodID reserve_method;
  jmethodID release_method;
  int width, height, max_packet, max_frames;
  std::atomic<bool> exhausted{false};
  SoftwareAccounting(JNIEnv* env, JavaVM* vm, jobject object, int width, int height, int packet, int frames)
      : vm(vm), budget(env->NewGlobalRef(object)), width(width), height(height), max_packet(packet), max_frames(frames) {
    jclass cls = env->GetObjectClass(object);
    reserve_method = env->GetMethodID(cls, "reserveNative", "(JI)J");
    release_method = env->GetMethodID(cls, "releaseNative", "(J)V");
    env->DeleteLocalRef(cls);
  }
  ~SoftwareAccounting() { SoftwareJniEnv call(vm); if (call.env && budget) call.env->DeleteGlobalRef(budget); }
  jlong reserve(int64_t bytes, int frames) {
    if (exhausted.load() || bytes <= 0) return 0;
    SoftwareJniEnv call(vm);
    if (!call.env || !reserve_method || !release_method) { exhausted.store(true); return 0; }
    jlong receipt = call.env->CallLongMethod(budget, reserve_method, static_cast<jlong>(bytes), frames);
    if (call.env->ExceptionCheck()) { call.env->ExceptionClear(); receipt = 0; }
    if (!receipt) exhausted.store(true);
    return receipt;
  }
  void release(jlong receipt) {
    if (!receipt) return;
    SoftwareJniEnv call(vm);
    if (call.env && release_method) {
      call.env->CallVoidMethod(budget, release_method, receipt);
      if (call.env->ExceptionCheck()) call.env->ExceptionClear();
    }
  }
};
struct SoftwareReceipt {
  std::shared_ptr<SoftwareAccounting> account;
  jlong receipt;
  SoftwareReceipt(std::shared_ptr<SoftwareAccounting> account, jlong receipt) : account(account), receipt(receipt) {}
  ~SoftwareReceipt() { account->release(receipt); }
};
struct SoftwareAllocator { std::shared_ptr<SoftwareAccounting> account; };

int software_get_buffer(AVCodecContext* decoder, AVFrame* frame, int) {
  auto account = static_cast<SoftwareAllocator*>(decoder->opaque)->account;
  // The existing GL output contract is 8-bit, limited-range BT.601. Never
  // silently truncate 10-bit or reinterpret a differently tagged stream.
  // AVC/HEVC allocate complete coding blocks before applying display crop.
  // Bound that padding; the received visible frame must still match exactly.
  const int padded_width = (account->width + 63) & ~63;
  const int padded_height = (account->height + 63) & ~63;
  if (frame->format != AV_PIX_FMT_YUV420P || frame->width < account->width || frame->height < account->height ||
      frame->width > padded_width || frame->height > padded_height) return AVERROR_INVALIDDATA;
  int width = frame->width, height = frame->height;
  int align[AV_NUM_DATA_POINTERS] = {};
  avcodec_align_dimensions2(decoder, &width, &height, align);
  if (width <= 0 || height <= 0 || width > 32768 || height > 32768) return AVERROR_INVALIDDATA;
  int size = av_image_get_buffer_size(AV_PIX_FMT_YUV420P, width, height, 64);
  if (size <= 0 || size > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) return AVERROR_INVALIDDATA;
  size += AV_INPUT_BUFFER_PADDING_SIZE;
  jlong receipt = account->reserve(size, 1);
  if (!receipt) return AVERROR(ENOMEM);
  auto* owned = new (std::nothrow) SoftwareReceipt(account, receipt);
  if (!owned) { account->release(receipt); return AVERROR(ENOMEM); }
  uint8_t* data = static_cast<uint8_t*>(av_mallocz(size));
  if (!data) { delete owned; return AVERROR(ENOMEM); }
  AVBufferRef* buffer = av_buffer_create(data, size, [](void* opaque, uint8_t* data) {
    av_free(data); delete static_cast<SoftwareReceipt*>(opaque);
  }, owned, 0);
  if (!buffer) { av_free(data); delete owned; return AVERROR(ENOMEM); }
  frame->buf[0] = buffer;
  if (av_image_fill_arrays(frame->data, frame->linesize, data, AV_PIX_FMT_YUV420P, width, height, 64) < 0) {
    av_buffer_unref(&frame->buf[0]); return AVERROR_INVALIDDATA;
  }
  frame->extended_data = frame->data;
  return 0;
}
