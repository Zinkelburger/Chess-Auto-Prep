#ifndef RUNNER_FILE_OPEN_CHANNEL_H_
#define RUNNER_FILE_OPEN_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

// Hands the files the desktop asked us to open (command-line paths, and paths
// forwarded by a second instance) to Dart over the `chess_auto_prep/file_open`
// method channel. Paths queue until Dart calls `ready`, so a file opened
// while the app is still starting is delivered rather than dropped.
class FileOpenChannel {
 public:
  FileOpenChannel() = default;

  FileOpenChannel(const FileOpenChannel&) = delete;
  FileOpenChannel& operator=(const FileOpenChannel&) = delete;

  // Connects the channel once the Flutter engine exists. Anything queued
  // before this stays queued until Dart is ready.
  void Attach(flutter::BinaryMessenger* messenger);

  // Delivers now if Dart is listening, otherwise queues. Paths are UTF-8.
  void Open(const std::vector<std::string>& paths);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<std::string> pending_;
  bool dart_ready_ = false;
};

#endif  // RUNNER_FILE_OPEN_CHANNEL_H_
