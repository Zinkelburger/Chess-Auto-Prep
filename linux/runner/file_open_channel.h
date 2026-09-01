#ifndef RUNNER_FILE_OPEN_CHANNEL_H_
#define RUNNER_FILE_OPEN_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

#include <string>
#include <vector>

// Hands the files the desktop asked us to open (command-line paths, and paths
// forwarded by a second instance) to Dart over the `chess_auto_prep/file_open`
// method channel. Paths queue until Dart calls `ready`, so a file opened
// while the app is still starting is delivered rather than dropped.
class FileOpenChannel {
 public:
  FileOpenChannel();
  ~FileOpenChannel();

  FileOpenChannel(const FileOpenChannel&) = delete;
  FileOpenChannel& operator=(const FileOpenChannel&) = delete;

  // Connects the channel once the Flutter engine exists. Anything queued
  // before this stays queued until Dart is ready.
  void Attach(FlBinaryMessenger* messenger);

  // Delivers now if Dart is listening, otherwise queues.
  void Open(const std::vector<std::string>& paths);

 private:
  static void OnMethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data);

  FlMethodChannel* channel_ = nullptr;
  std::vector<std::string> pending_;
  bool dart_ready_ = false;
};

#endif  // RUNNER_FILE_OPEN_CHANNEL_H_
