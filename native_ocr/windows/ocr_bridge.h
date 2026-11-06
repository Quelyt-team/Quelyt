#ifndef LOCAL_STUDY_OCR_BRIDGE_H_
#define LOCAL_STUDY_OCR_BRIDGE_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <thread>

// The OCR worker posts completion to the Flutter platform thread. It never
// invokes a MethodResult directly from its background COM apartment.
class OcrBridge {
 public:
  static constexpr UINT kCompletionMessage = WM_APP + 0x431;
  OcrBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~OcrBridge();
  bool HandleWindowMessage(UINT message, LPARAM lparam);

 private:
  struct Completion;
  void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Recognize(std::string path, std::string language,
                 std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_;
  std::atomic<bool> closing_{false};
  std::atomic<bool> busy_{false};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::thread worker_;
};

#endif  // LOCAL_STUDY_OCR_BRIDGE_H_
