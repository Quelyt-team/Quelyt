#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>
#define EXPORT extern "C" __declspec(dllexport)
#else
#include <dlfcn.h>
#include <pthread.h>
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {
constexpr size_t kWorkerStack = 6 * 1024 * 1024;
constexpr size_t kJsStack = 3 * 1024 * 1024;
constexpr size_t kMaxSource = 3 * 1024 * 1024;
constexpr size_t kMaxResult = 320000;
using HostCallback = void* (*)(void*, size_t, void*);

void* NoHostAccess(void*, size_t, void*) { return nullptr; }

// The pinned QuickJS plugin ships a C ABI that does not expose JSValue's
// platform-dependent layout. Load it once on the worker thread.
class JsEngine {
 public:
  bool Initialize() {
#ifdef _WIN32
    library_ = GetModuleHandleW(L"flutter_qjs_next_plugin.dll");
#else
    library_ = dlopen("libflutter_qjs_next.so", RTLD_NOW | RTLD_LOCAL);
#endif
    if (!library_) return false;
    const auto create = Load<void* (*)(HostCallback, int64_t)>("jsNewRuntime");
    const auto make_context = Load<void* (*)(void*)>("jsNewContext");
    const auto memory = Load<void (*)(void*, size_t)>("jsSetMemoryLimit");
    const auto stack = Load<void (*)(void*, size_t)>("jsSetMaxStackSize");
    eval_ = Load<void* (*)(void*, const char*, size_t, const char*, int32_t)>("jsEval");
    error_ = Load<int32_t (*)(void*)>("jsIsException");
    text_ = Load<const char* (*)(void*, void*, size_t*)>("jsToCString");
    free_text_ = Load<void (*)(void*, const char*)>("jsFreeCString");
    free_value_ = Load<void (*)(void*, void*, int32_t)>("jsFreeValue");
    exception_ = Load<void* (*)(void*)>("jsGetException");
    if (!create || !make_context || !memory || !stack || !eval_ || !error_ ||
        !text_ || !free_text_ || !free_value_ || !exception_) {
      return false;
    }
    runtime_ = create(NoHostAccess, 1800);
    if (!runtime_) return false;
    memory(runtime_, 64 * 1024 * 1024);
    stack(runtime_, kJsStack);
    context_ = make_context(runtime_);
    return context_ != nullptr;
  }

  std::string Evaluate(const char* source, size_t length) {
    auto* value = eval_(context_, source, length, "quelyt-formula.js", 0);
    if (!value) return {};
    std::string result;
    if (!error_(value)) {
      size_t size = 0;
      const auto* message = text_(context_, value, &size);
      if (message) {
        if (size <= kMaxResult) result.assign(message, size);
        free_text_(context_, message);
      }
    } else {
      if (auto* error = exception_(context_)) free_value_(context_, error, 1);
    }
    free_value_(context_, value, 1);
    return result;
  }

 private:
  template <typename T>
  T Load(const char* name) {
#ifdef _WIN32
    return reinterpret_cast<T>(GetProcAddress(library_, name));
#else
    return reinterpret_cast<T>(dlsym(library_, name));
#endif
  }
#ifdef _WIN32
  HMODULE library_ = nullptr;
#else
  void* library_ = nullptr;
#endif
  void* runtime_ = nullptr;
  void* context_ = nullptr;
  void* (*eval_)(void*, const char*, size_t, const char*, int32_t) = nullptr;
  int32_t (*error_)(void*) = nullptr;
  const char* (*text_)(void*, void*, size_t*) = nullptr;
  void (*free_text_)(void*, const char*) = nullptr;
  void (*free_value_)(void*, void*, int32_t) = nullptr;
  void* (*exception_)(void*) = nullptr;
};

class Worker {
 public:
  Worker() {
#ifdef _WIN32
    const auto handle = reinterpret_cast<HANDLE>(_beginthreadex(
        nullptr, kWorkerStack, Entry, this, STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr));
    if (handle) {
      CloseHandle(handle);
      started_ = true;
    }
#else
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes) == 0) {
      pthread_t thread;
      if (pthread_attr_setstacksize(&attributes, kWorkerStack) == 0 &&
          pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED) == 0) {
        started_ = pthread_create(&thread, &attributes, Entry, this) == 0;
      }
      pthread_attr_destroy(&attributes);
    }
#endif
  }

  std::string Evaluate(const char* input, size_t length) {
    if (!started_) return {};
    std::lock_guard<std::mutex> caller(call_mutex_);
    std::unique_lock<std::mutex> lock(mutex_);
    input_ = input;
    length_ = length;
    pending_ = true;
    condition_.notify_one();
    condition_.wait(lock, [this] { return !pending_; });
    return std::move(output_);
  }

 private:
#ifdef _WIN32
  static unsigned __stdcall Entry(void* value) {
    static_cast<Worker*>(value)->Run();
    return 0;
  }
#else
  static void* Entry(void* value) {
    static_cast<Worker*>(value)->Run();
    return nullptr;
  }
#endif
  void Run() {
    JsEngine engine;
    const bool ready = engine.Initialize();
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
      condition_.wait(lock, [this] { return pending_; });
      try {
        output_ = ready ? engine.Evaluate(input_, length_) : std::string{};
      } catch (...) {
        output_.clear();
      }
      pending_ = false;
      condition_.notify_one();
    }
  }

  bool started_ = false;
  bool pending_ = false;
  const char* input_ = nullptr;
  size_t length_ = 0;
  std::string output_;
  std::mutex call_mutex_;
  std::mutex mutex_;
  std::condition_variable condition_;
};
}  // namespace

EXPORT char* quelyt_formula_evaluate(const char* source, size_t length) {
  if (!source || length == 0 || length > kMaxSource) return nullptr;
  try {
    // The engine belongs to the application process and is reused by every
    // answer, note and PDF. The operating system reclaims it on exit.
    static Worker* worker = new Worker();
    const auto result = worker->Evaluate(source, length);
    if (result.empty()) return nullptr;
    auto* buffer = static_cast<char*>(std::malloc(result.size() + 1));
    if (buffer) std::memcpy(buffer, result.c_str(), result.size() + 1);
    return buffer;
  } catch (...) {
    return nullptr;
  }
}

EXPORT void quelyt_formula_free(char* value) { std::free(value); }
