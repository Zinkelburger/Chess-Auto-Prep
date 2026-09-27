import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var fileChannel: FlutterMethodChannel?
  private var pendingFiles: [String] = []
  private var filesReady = false
  // Finder grants access to external files. Keep scoped grants for this
  // process while Dart imports the selected file into its Documents folder.
  private var scopedFiles: [URL] = []

  func attachFileOpenChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "chess_auto_prep/file_open", binaryMessenger: messenger)
    fileChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.filesReady = true
      let files = self.pendingFiles
      self.pendingFiles.removeAll()
      result(files)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter { $0.isFileURL }
    for url in files {
      if url.startAccessingSecurityScopedResource() { scopedFiles.append(url) }
    }
    let paths = files.map { $0.path }
    if !paths.isEmpty {
      if filesReady {
        fileChannel?.invokeMethod("open", arguments: paths)
      } else {
        pendingFiles.append(contentsOf: paths)
      }
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
      application.activate(ignoringOtherApps: true)
    }
    let otherURLs = urls.filter { !$0.isFileURL }
    if !otherURLs.isEmpty { super.application(application, open: otherURLs) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
