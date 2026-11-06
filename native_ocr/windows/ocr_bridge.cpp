#include "ocr_bridge.h"

#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Microsoft::WRL::ComPtr;

void Check(HRESULT result) {
  if (FAILED(result)) throw std::runtime_error("无法解码本机图片。");
}

struct WorkerApartment {
  WorkerApartment() { Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); }
  ~WorkerApartment() { CoUninitialize(); }
};

std::filesystem::path ExecutableDirectory() {
  std::vector<wchar_t> buffer(32768);
  const auto length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) throw std::runtime_error("无法定位应用目录。");
  return std::filesystem::path(std::wstring(buffer.data(), length)).parent_path();
}

// Tesseract's Windows fopen uses the process active code page. The runner's
// manifest opts into UTF-8, so paths remain valid for every Windows user name.
std::string NativePath(const std::filesystem::path& path) {
  const auto wide = path.wstring();
  const auto code_page = GetACP();
  BOOL replaced = FALSE;
  const auto flags = code_page == CP_UTF8 ? 0u : WC_NO_BEST_FIT_CHARS;
  const auto count = WideCharToMultiByte(code_page, flags, wide.c_str(), -1,
      nullptr, 0, nullptr, code_page == CP_UTF8 ? nullptr : &replaced);
  if (count == 0 || replaced) throw std::runtime_error("当前进程不支持此模型路径，请使用应用安装版。");
  std::string value(static_cast<size_t>(count), '\0');
  if (WideCharToMultiByte(code_page, flags, wide.c_str(), -1, value.data(), count,
      nullptr, code_page == CP_UTF8 ? nullptr : &replaced) == 0 || replaced) {
    throw std::runtime_error("无法转换模型路径。");
  }
  value.pop_back();
  return value;
}

std::string Argument(const Value* value, const char* key) {
  if (!value) return {};
  const auto* map = std::get_if<Map>(value);
  if (!map) return {};
  const auto item = map->find(Value(key));
  if (item == map->end()) return {};
  const auto* text = std::get_if<std::string>(&item->second);
  return text ? *text : std::string();
}

std::wstring Utf8Path(const std::string& value) {
  const auto size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) throw std::runtime_error("图片路径无效。");
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), size);
  return result;
}

// Stable Tesseract 5 C API. Load only the bundled DLLs, never PATH or user CWD.
class Tesseract {
 public:
  using Create = void* (__cdecl*)();
  using Delete = void (__cdecl*)(void*);
  using Init = int (__cdecl*)(void*, const char*, const char*, int);
  using SetImage = void (__cdecl*)(void*, const unsigned char*, int, int, int, int);
  using SetMode = void (__cdecl*)(void*, int);
  using Text = char* (__cdecl*)(void*);
  using TextDelete = void (__cdecl*)(const char*);
  using Iterator = void* (__cdecl*)(void*);
  using IteratorText = char* (__cdecl*)(const void*, int);
  using IteratorConfidence = float (__cdecl*)(const void*, int);
  using IteratorNext = int (__cdecl*)(void*, int);
  using BoundingBox = int (__cdecl*)(const void*, int, int*, int*, int*, int*);
  using Recognize = int (__cdecl*)(void*, void*);
  using MonitorDeadline = void (__cdecl*)(void*, int);
  using Cancel = bool (__cdecl*)(void*, int);
  using MonitorCancel = void (__cdecl*)(void*, Cancel);
  using MonitorContext = void (__cdecl*)(void*, void*);

  explicit Tesseract(const std::filesystem::path& directory) {
    const auto runtime = directory / L"ocr";
    const auto flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32;
    leptonica_ = LoadLibraryExW((runtime / L"leptonica-1.82.0.dll").c_str(), nullptr, flags);
    if (!leptonica_) throw std::runtime_error("缺少内置 OCR 运行库或 Microsoft VC++ 运行时。");
    library_ = LoadLibraryExW((runtime / L"tesseract50.dll").c_str(), nullptr, flags);
    if (!library_) {
      FreeLibrary(leptonica_);
      leptonica_ = nullptr;
      throw std::runtime_error("无法加载内置 Tesseract OCR。");
    }
    try {
      create = Symbol<Create>("TessBaseAPICreate");
      destroy = Symbol<Delete>("TessBaseAPIDelete");
      init = Symbol<Init>("TessBaseAPIInit2");
      set_image = Symbol<SetImage>("TessBaseAPISetImage");
      set_mode = Symbol<SetMode>("TessBaseAPISetPageSegMode");
      text = Symbol<Text>("TessBaseAPIGetUTF8Text");
      text_delete = Symbol<TextDelete>("TessDeleteText");
      iterator = Symbol<Iterator>("TessBaseAPIGetIterator");
      iterator_delete = Symbol<Delete>("TessResultIteratorDelete");
      page_iterator = Symbol<Iterator>("TessResultIteratorGetPageIterator");
      iterator_text = Symbol<IteratorText>("TessResultIteratorGetUTF8Text");
      iterator_confidence = Symbol<IteratorConfidence>("TessResultIteratorConfidence");
      iterator_next = Symbol<IteratorNext>("TessResultIteratorNext");
      bounding_box = Symbol<BoundingBox>("TessPageIteratorBoundingBox");
      recognize = Symbol<Recognize>("TessBaseAPIRecognize");
      monitor_create = Symbol<Create>("TessMonitorCreate");
      monitor_delete = Symbol<Delete>("TessMonitorDelete");
      monitor_deadline = Symbol<MonitorDeadline>("TessMonitorSetDeadlineMSecs");
      monitor_cancel = Symbol<MonitorCancel>("TessMonitorSetCancelFunc");
      monitor_context = Symbol<MonitorContext>("TessMonitorSetCancelThis");
    } catch (...) {
      FreeLibrary(library_);
      FreeLibrary(leptonica_);
      throw;
    }
  }
  ~Tesseract() {
    if (library_) FreeLibrary(library_);
    if (leptonica_) FreeLibrary(leptonica_);
  }
  Tesseract(const Tesseract&) = delete;
  Tesseract& operator=(const Tesseract&) = delete;

  Create create{}, monitor_create{};
  Delete destroy{}, iterator_delete{}, monitor_delete{};
  Init init{};
  SetImage set_image{};
  SetMode set_mode{};
  Text text{};
  TextDelete text_delete{};
  Iterator iterator{}, page_iterator{};
  IteratorText iterator_text{};
  IteratorConfidence iterator_confidence{};
  IteratorNext iterator_next{};
  BoundingBox bounding_box{};
  Recognize recognize{};
  MonitorDeadline monitor_deadline{};
  MonitorCancel monitor_cancel{};
  MonitorContext monitor_context{};

 private:
  template<typename Function>
  Function Symbol(const char* name) {
    const auto address = GetProcAddress(library_, name);
    if (!address) throw std::runtime_error("内置 OCR 运行库版本不匹配。");
    Function function;
    static_assert(sizeof(function) == sizeof(address));
    std::memcpy(&function, &address, sizeof(function));
    return function;
  }
  HMODULE leptonica_ = nullptr;
  HMODULE library_ = nullptr;
};

struct Pixels {
  int width;
  int height;
  std::vector<unsigned char> rgb;
};

Pixels ReadPixels(const std::string& path) {
  ComPtr<IWICImagingFactory> factory;
  Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(factory.GetAddressOf())));
  ComPtr<IWICBitmapDecoder> decoder;
  Check(factory->CreateDecoderFromFilename(Utf8Path(path).c_str(), nullptr, GENERIC_READ,
      WICDecodeMetadataCacheOnLoad, decoder.GetAddressOf()));
  ComPtr<IWICBitmapFrameDecode> frame;
  Check(decoder->GetFrame(0, frame.GetAddressOf()));
  ComPtr<IWICBitmapSource> source;
  Check(frame.As(&source));
  USHORT orientation = 1;
  ComPtr<IWICMetadataQueryReader> metadata;
  if (SUCCEEDED(frame->GetMetadataQueryReader(metadata.GetAddressOf()))) {
    for (const auto key : {L"/app1/ifd/{ushort=274}", L"/ifd/{ushort=274}"}) {
      PROPVARIANT value;
      PropVariantInit(&value);
      if (SUCCEEDED(metadata->GetMetadataByName(key, &value)) && value.vt == VT_UI2) {
        orientation = value.uiVal;
      }
      PropVariantClear(&value);
    }
  }
  WICBitmapTransformOptions rotation = WICBitmapTransformRotate0;
  switch (orientation) {
    case 2: rotation = WICBitmapTransformFlipHorizontal; break;
    case 3: rotation = WICBitmapTransformRotate180; break;
    case 4: rotation = WICBitmapTransformFlipVertical; break;
    case 5: rotation = static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal); break;
    case 6: rotation = WICBitmapTransformRotate90; break;
    case 7: rotation = static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal); break;
    case 8: rotation = WICBitmapTransformRotate270; break;
    default: break;
  }
  if (rotation != WICBitmapTransformRotate0) {
    ComPtr<IWICBitmapFlipRotator> rotated;
    Check(factory->CreateBitmapFlipRotator(rotated.GetAddressOf()));
    Check(rotated->Initialize(source.Get(), rotation));
    Check(rotated.As(&source));
  }
  UINT width = 0, height = 0;
  Check(source->GetSize(&width, &height));
  if (width == 0 || height == 0) throw std::runtime_error("图片尺寸无效。");
  const auto scale = std::min(1.0, 2800.0 / std::max(width, height));
  if (scale < 1.0) {
    ComPtr<IWICBitmapScaler> scaler;
    Check(factory->CreateBitmapScaler(scaler.GetAddressOf()));
    width = std::max(1u, static_cast<UINT>(std::round(width * scale)));
    height = std::max(1u, static_cast<UINT>(std::round(height * scale)));
    Check(scaler->Initialize(source.Get(), width, height, WICBitmapInterpolationModeFant));
    Check(scaler.As(&source));
  }
  ComPtr<IWICFormatConverter> converter;
  Check(factory->CreateFormatConverter(converter.GetAddressOf()));
  Check(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppRGBA,
      WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom));
  std::vector<unsigned char> rgba(static_cast<size_t>(width) * height * 4);
  Check(converter->CopyPixels(nullptr, width * 4, static_cast<UINT>(rgba.size()), rgba.data()));
  Pixels result{static_cast<int>(width), static_cast<int>(height),
      std::vector<unsigned char>(static_cast<size_t>(width) * height * 3)};
  for (size_t i = 0; i < static_cast<size_t>(width) * height; ++i) {
    const auto alpha = rgba[i * 4 + 3];
    for (size_t channel = 0; channel < 3; ++channel) {
      result.rgb[i * 3 + channel] = static_cast<unsigned char>(
          (rgba[i * 4 + channel] * alpha + 255 * (255 - alpha)) / 255);
    }
  }
  return result;
}

bool __cdecl CancelRecognition(void* context, int) {
  return static_cast<std::atomic<bool>*>(context)->load();
}

std::filesystem::path ModelDirectory(const std::filesystem::path& application) {
  return application / L"data" / L"flutter_assets" / L"assets" / L"ocr";
}

Map Availability() {
  bool available = false;
  std::string message;
  try {
    const auto application = ExecutableDirectory();
    const Tesseract library(application);
    const auto models = ModelDirectory(application);
    available = std::filesystem::exists(models / L"chi_sim.traineddata") &&
        std::filesystem::exists(models / L"eng.traineddata");
    message = available ? "中英文 OCR 模型随应用内置，可离线识别正文。公式与表格请核对原图。"
                        : "安装目录缺少内置 OCR 模型，请重新安装完整应用。";
  } catch (const std::exception& error) {
    message = error.what();
  }
  return Map{{Value("available"), Value(available)},
             {Value("backend"), Value("tesseract_bundled")},
             {Value("languages"), Value(available ? List{Value("zh-Hans"), Value("en")} : List{})},
             {Value("message"), Value(message)}};
}
}  // namespace

struct OcrBridge::Completion {
  std::unique_ptr<flutter::MethodResult<Value>> result;
  Map value;
  std::string code;
  std::string message;
};

OcrBridge::OcrBridge(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<Value>>(
          messenger, "local_study/ocr", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });
}

OcrBridge::~OcrBridge() {
  closing_ = true;
  channel_->SetMethodCallHandler(nullptr);
  if (worker_.joinable()) worker_.join();
  MSG message;
  while (PeekMessage(&message, window_, kCompletionMessage, kCompletionMessage, PM_REMOVE)) {
    delete reinterpret_cast<Completion*>(message.lParam);
  }
}

bool OcrBridge::HandleWindowMessage(UINT message, LPARAM lparam) {
  if (message != kCompletionMessage) return false;
  std::unique_ptr<Completion> completion(reinterpret_cast<Completion*>(lparam));
  if (completion->code.empty()) {
    completion->result->Success(Value(completion->value));
  } else {
    completion->result->Error(completion->code, completion->message);
  }
  return true;
}

void OcrBridge::HandleCall(const flutter::MethodCall<Value>& call,
                          std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (call.method_name() == "availability") {
    result->Success(Value(Availability()));
    return;
  }
  if (call.method_name() != "recognizeImage") {
    result->NotImplemented();
    return;
  }
  const auto path = Argument(call.arguments(), "path");
  const auto language = Argument(call.arguments(), "language");
  if (path.empty()) {
    result->Error("invalid_path", "缺少本机图片路径。");
    return;
  }
  if (busy_.exchange(true)) {
    result->Error("ocr_busy", "另一页正在识别，请稍后重试。");
    return;
  }
  if (worker_.joinable()) worker_.join();
  auto response = std::make_shared<std::unique_ptr<flutter::MethodResult<Value>>>(std::move(result));
  try {
    worker_ = std::thread([this, path, language, response]() mutable {
      Recognize(path, language, std::move(*response));
    });
  } catch (const std::exception&) {
    busy_ = false;
    (*response)->Error("ocr_unavailable", "无法创建本地 OCR 后台任务。");
  }
}

void OcrBridge::Recognize(std::string path, std::string language,
                         std::unique_ptr<flutter::MethodResult<Value>> result) {
  auto completion = std::make_unique<Completion>();
  completion->result = std::move(result);
  try {
    const WorkerApartment apartment;
    const auto application = ExecutableDirectory();
    Tesseract library(application);
    const auto data_path = NativePath(ModelDirectory(application));
    const auto languages = language.rfind("en", 0) == 0 ? "eng" : "chi_sim+eng";
    std::unique_ptr<void, Tesseract::Delete> api(library.create(), library.destroy);
    if (!api || library.init(api.get(), data_path.c_str(), languages, 1) != 0) {
      throw std::runtime_error("无法加载内置中英文 OCR 模型，请重新安装完整应用。");
    }
    const auto pixels = ReadPixels(path);
    library.set_mode(api.get(), 3);  // PSM_AUTO; no OSD model/network dependency.
    library.set_image(api.get(), pixels.rgb.data(), pixels.width, pixels.height, 3, pixels.width * 3);
    std::unique_ptr<void, Tesseract::Delete> monitor(library.monitor_create(), library.monitor_delete);
    if (!monitor) throw std::runtime_error("无法初始化 OCR 任务。");
    library.monitor_deadline(monitor.get(), 80000);
    library.monitor_context(monitor.get(), &closing_);
    library.monitor_cancel(monitor.get(), CancelRecognition);
    if (library.recognize(api.get(), monitor.get()) != 0) {
      throw std::runtime_error("本页 OCR 超时或识别失败，请缩小图片后重试。");
    }
    std::unique_ptr<const char, Tesseract::TextDelete> text(library.text(api.get()), library.text_delete);
    List blocks;
    std::unique_ptr<void, Tesseract::Delete> iterator(library.iterator(api.get()), library.iterator_delete);
    constexpr int line_level = 2;
    if (iterator) {
      do {
        int left = 0, top = 0, right = 0, bottom = 0;
        const auto page_iterator = library.page_iterator(iterator.get());
        std::unique_ptr<const char, Tesseract::TextDelete> line(
            library.iterator_text(iterator.get(), line_level), library.text_delete);
        if (!line || !*line.get() || !library.bounding_box(page_iterator, line_level,
            &left, &top, &right, &bottom)) continue;
        blocks.emplace_back(Map{
          {Value("text"), Value(std::string(line.get()))},
          {Value("left"), Value(std::clamp(static_cast<double>(left) / pixels.width, 0.0, 1.0))},
          {Value("top"), Value(std::clamp(static_cast<double>(top) / pixels.height, 0.0, 1.0))},
          {Value("right"), Value(std::clamp(static_cast<double>(right) / pixels.width, 0.0, 1.0))},
          {Value("bottom"), Value(std::clamp(static_cast<double>(bottom) / pixels.height, 0.0, 1.0))},
          {Value("confidence"), Value(std::clamp(library.iterator_confidence(iterator.get(), line_level) / 100.0, 0.0, 1.0))},
        });
      } while (library.iterator_next(iterator.get(), line_level));
    }
    completion->value = Map{
      {Value("text"), Value(text ? std::string(text.get()) : std::string())},
      {Value("blocks"), Value(blocks)},
      {Value("width"), Value(pixels.width)},
      {Value("height"), Value(pixels.height)},
      {Value("backend"), Value("tesseract_bundled")},
    };
  } catch (const std::exception& error) {
    completion->code = "ocr_failed";
    completion->message = error.what();
  } catch (...) {
    completion->code = "ocr_failed";
    completion->message = "本地 OCR 失败，请核对图片后重试。";
  }
  busy_ = false;
  if (!closing_ && PostMessage(window_, kCompletionMessage, 0,
                              reinterpret_cast<LPARAM>(completion.get()))) {
    completion.release();
  }
}
