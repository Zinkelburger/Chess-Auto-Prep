#include "file_open_channel.h"

static const char kChannelName[] = "chess_auto_prep/file_open";

static FlValue* paths_to_value(const std::vector<std::string>& paths) {
  FlValue* list = fl_value_new_list();
  for (const std::string& path : paths) {
    fl_value_append_take(list, fl_value_new_string(path.c_str()));
  }
  return list;
}

FileOpenChannel::FileOpenChannel() {}

FileOpenChannel::~FileOpenChannel() {
  g_clear_object(&channel_);
}

void FileOpenChannel::Attach(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(messenger, kChannelName,
                                   FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_, OnMethodCall, this,
                                            nullptr);
}

void FileOpenChannel::Open(const std::vector<std::string>& paths) {
  if (paths.empty()) return;
  if (!dart_ready_ || channel_ == nullptr) {
    pending_.insert(pending_.end(), paths.begin(), paths.end());
    return;
  }
  g_autoptr(FlValue) args = paths_to_value(paths);
  fl_method_channel_invoke_method(channel_, "open", args, nullptr, nullptr,
                                  nullptr);
}

// static
void FileOpenChannel::OnMethodCall(FlMethodChannel* channel,
                                   FlMethodCall* method_call,
                                   gpointer user_data) {
  auto* self = static_cast<FileOpenChannel*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(GError) error = nullptr;

  if (g_strcmp0(method, "ready") != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, &error);
    return;
  }

  self->dart_ready_ = true;
  g_autoptr(FlValue) result = paths_to_value(self->pending_);
  self->pending_.clear();
  fl_method_call_respond_success(method_call, result, &error);
  if (error != nullptr) {
    g_warning("file_open: failed to answer ready: %s", error->message);
  }
}
