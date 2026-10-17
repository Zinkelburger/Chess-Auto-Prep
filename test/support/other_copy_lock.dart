import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:chess_auto_prep/storage/file_lock.dart';

/// Another copy of the app holding [directory]'s lock: the same
/// [withDirectoryLock], on an isolate of its own, so only the lock itself
/// keeps the two apart. Answers once the lock is held, with the call that
/// lets it go.
Future<Future<void> Function()> holdLockElsewhere(Directory directory) async {
  final path = directory.path;
  final messages = ReceivePort();
  await Isolate.spawn((SendPort reply) async {
    final release = ReceivePort();
    await withDirectoryLock(Directory(path), () async {
      reply.send(release.sendPort);
      await release.first;
    });
    reply.send(null);
  }, messages.sendPort);
  final events = StreamIterator<Object?>(messages);
  if (!await events.moveNext()) throw StateError('the holder never started');
  final release = events.current! as SendPort;
  return () async {
    release.send(null);
    await events.moveNext();
    await events.cancel();
  };
}
