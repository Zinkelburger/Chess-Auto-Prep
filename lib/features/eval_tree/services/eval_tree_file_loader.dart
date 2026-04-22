library;

import 'eval_tree_file_loader_stub.dart'
    if (dart.library.io) 'eval_tree_file_loader_io.dart' as impl;

bool get isEvalTreeFileAccessSupported => impl.isEvalTreeFileAccessSupported;

String get evalTreeFileAccessUnsupportedReason =>
    impl.evalTreeFileAccessUnsupportedReason;

Future<bool> evalTreeFileExists(String path) => impl.evalTreeFileExists(path);

Future<String> readEvalTreeFile(String path) => impl.readEvalTreeFile(path);
