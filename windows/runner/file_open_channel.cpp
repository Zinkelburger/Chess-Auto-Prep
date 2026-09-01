#include "file_open_channel.h"

#include <flutter/standard_method_codec.h>

namespace {

constexpr char kChannelName[] = "chess_auto_prep/file_open";

flutter::EncodableValue PathsToValue(const std::vector<std::string>& paths) {
  flutter::EncodableList list;
  for (const std::string& path : paths) {
    list.push_back(flutter::EncodableValue(path));
  }
  return flutter::EncodableValue(list);
}

}  // namespace

void FileOpenChannel::Attach(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "ready") {
          result->NotImplemented();
          return;
        }
        dart_ready_ = true;
        flutter::EncodableValue pending = PathsToValue(pending_);
        pending_.clear();
        result->Success(pending);
      });
}

void FileOpenChannel::Open(const std::vector<std::string>& paths) {
  if (paths.empty()) return;
  if (!dart_ready_ || !channel_) {
    pending_.insert(pending_.end(), paths.begin(), paths.end());
    return;
  }
  channel_->InvokeMethod(
      "open", std::make_unique<flutter::EncodableValue>(PathsToValue(paths)));
}
