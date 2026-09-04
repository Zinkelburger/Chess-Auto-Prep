import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/features/bughouse/services/windows_loader_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The check that explains a Windows machine the engine will not start on.
///
/// All of it runs on any host, deliberately: the failure it exists for happens
/// on other people's machines, and a check that could only be exercised there
/// would be a check nobody ever ran. The fixtures below are real PE headers,
/// built byte by byte, because the only thing that matters is the two bytes
/// the Windows loader itself looks at.
void main() {
  /// A minimal PE image declaring [machine]: an MZ header, the offset to the
  /// PE signature at 0x3C, and the COFF machine field right after it.
  Uint8List pe(int machine, {int peAt = 0x80, int length = 0x200}) {
    final bytes = Uint8List(length);
    final data = ByteData.sublistView(bytes);
    bytes[0] = 0x4D; // 'M'
    bytes[1] = 0x5A; // 'Z'
    data.setUint32(0x3C, peAt, Endian.little);
    bytes[peAt] = 0x50; // 'P'
    bytes[peAt + 1] = 0x45; // 'E'
    data.setUint16(peAt + 4, machine, Endian.little);
    return bytes;
  }

  group('peMachine', () {
    test('reads the two bytes the loader reads', () {
      expect(
        WindowsLoaderCheck.peMachine(pe(0x8664)),
        WindowsLoaderCheck.amd64,
      );
      expect(WindowsLoaderCheck.peMachine(pe(0x014c)), 0x014c);
      expect(WindowsLoaderCheck.peMachine(pe(0xaa64)), 0xaa64);
    });

    test('a file that is not a PE is not a machine', () {
      expect(WindowsLoaderCheck.peMachine(Uint8List(0x200)), isNull);
      expect(
        WindowsLoaderCheck.peMachine(
          Uint8List.fromList(utf8Bytes('#!/bin/sh')),
        ),
        isNull,
      );
    });

    // The interesting one: a half-written extraction is an MZ header with
    // nothing behind it, and Windows rejects it with the same status as a
    // 32-bit DLL. Reading past the end must not throw.
    test('a truncated image is rejected rather than thrown over', () {
      final whole = pe(0x8664);
      expect(WindowsLoaderCheck.peMachine(whole.sublist(0, 0x40)), isNull);
      expect(WindowsLoaderCheck.peMachine(whole.sublist(0, 8)), isNull);
      expect(WindowsLoaderCheck.peMachine(Uint8List(0)), isNull);
    });

    test('an MZ header pointing past the end is rejected', () {
      final bytes = Uint8List(0x200);
      bytes[0] = 0x4D;
      bytes[1] = 0x5A;
      ByteData.sublistView(bytes).setUint32(0x3C, 0x9000, Endian.little);
      expect(WindowsLoaderCheck.peMachine(bytes), isNull);
    });
  });

  group('searchOrder', () {
    test('is the order the loader uses, engine directory first', () {
      final order = WindowsLoaderCheck.searchOrder(
        engineDir: r'C:\support\bughouse',
        environment: {
          'SystemRoot': r'C:\Windows',
          'Path': r'C:\tools\bin;C:\other',
        },
      );
      expect(order.first, r'C:\support\bughouse');
      expect(order[1], contains('System32'));
      expect(order.last, r'C:\other');
    });

    test('finds PATH however the parent spelled it', () {
      for (final key in ['PATH', 'Path', 'path']) {
        final order = WindowsLoaderCheck.searchOrder(
          engineDir: r'C:\e',
          environment: {'SystemRoot': r'C:\Windows', key: r'C:\only'},
        );
        expect(order, contains(r'C:\only'), reason: 'spelled $key');
      }
    });

    test('survives an environment with no PATH and no SystemRoot', () {
      final order = WindowsLoaderCheck.searchOrder(
        engineDir: r'C:\e',
        environment: const {},
      );
      expect(order.first, r'C:\e');
      expect(order.any((d) => d.contains('System32')), isTrue);
    });
  });

  group('resolve', () {
    late Directory root;
    late Directory first;
    late Directory second;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('loader-check');
      first = await Directory(p.join(root.path, 'engine')).create();
      second = await Directory(p.join(root.path, 'onpath')).create();
    });

    tearDown(() async => root.delete(recursive: true));

    test(
      'takes the first directory that has the file, as the loader does',
      () async {
        await File(p.join(first.path, 'MSVCP140.dll')).writeAsBytes(pe(0x8664));
        await File(
          p.join(second.path, 'MSVCP140.dll'),
        ).writeAsBytes(pe(0x014c));

        final found = await WindowsLoaderCheck.resolve('MSVCP140.dll', [
          first.path,
          second.path,
        ]);
        expect(found.path, p.join(first.path, 'MSVCP140.dll'));
        expect(found.isWrongArchitecture, isFalse);
      },
    );

    // The whole point: the copy beside the engine is missing, so a stray
    // 32-bit one further down the search order is what Windows loads.
    test('reports the 32-bit copy that wins when ours is absent', () async {
      await File(p.join(second.path, 'MSVCP140.dll')).writeAsBytes(pe(0x014c));

      final found = await WindowsLoaderCheck.resolve('MSVCP140.dll', [
        first.path,
        second.path,
      ]);
      expect(found.isWrongArchitecture, isTrue);
      expect(found.path, contains('onpath'));
      expect(
        WindowsLoaderCheck.describe([found]),
        allOf(contains('32-bit'), contains(second.path)),
      );
    });

    test('a truncated extraction reads as unloadable, not as fine', () async {
      final half = pe(0x8664).sublist(0, 0x20);
      await File(p.join(first.path, 'onnxruntime.dll')).writeAsBytes(half);

      final found = await WindowsLoaderCheck.resolve('onnxruntime.dll', [
        first.path,
      ]);
      expect(found.isWrongArchitecture, isTrue);
      expect(
        WindowsLoaderCheck.describe([found]),
        contains('not a Windows program at all'),
      );
    });

    test('nowhere on the search path is nowhere', () async {
      final found = await WindowsLoaderCheck.resolve('dxgi.dll', [first.path]);
      expect(found.isMissing, isTrue);
      expect(found.isWrongArchitecture, isFalse);
    });
  });

  group('describe', () {
    test('says nothing when every library is a 64-bit one', () {
      expect(
        WindowsLoaderCheck.describe(const [
          DllResolution(
            name: 'MSVCP140.dll',
            path: r'C:\e\MSVCP140.dll',
            machine: WindowsLoaderCheck.amd64,
          ),
        ]),
        isNull,
      );
    });

    /// Windows itself ships SETUPAPI/dbghelp/dxgi, so "not found" for one of
    /// those is a machine so broken that saying it would only mislead. The
    /// four the app is responsible for are a different matter.
    test('only complains about a missing library the app owes', () {
      expect(
        WindowsLoaderCheck.describe(const [
          DllResolution(name: 'dxgi.dll', path: null, machine: null),
        ]),
        isNull,
      );
      expect(
        WindowsLoaderCheck.describe(const [
          DllResolution(name: 'VCRUNTIME140.dll', path: null, machine: null),
        ]),
        contains('Redistributable'),
      );
    });

    /// Naming the redistributable is no use to someone who then has to find
    /// it. The link is the difference between a fixable machine and a user
    /// who gives up, so it travels with the sentence.
    test('gives the download, not just the name of it', () {
      expect(
        WindowsLoaderCheck.describe(const [
          DllResolution(name: 'VCRUNTIME140.dll', path: null, machine: null),
        ]),
        contains(WindowsLoaderCheck.redistributableUrl),
      );
    });
  });

  group('needsRedistributable', () {
    test('is true when a library the app owes resolves nowhere', () {
      expect(
        WindowsLoaderCheck.needsRedistributable(const [
          DllResolution(name: 'MSVCP140_1.dll', path: null, machine: null),
        ]),
        isTrue,
      );
    });

    /// The offer has to be narrow. Installing 25 MB of Microsoft runtime does
    /// nothing for a file that is present and damaged, or for a library
    /// Windows itself owns — and having sent someone there once for nothing,
    /// we do not get to send them again for the case it would have fixed.
    test(
      'is false for a library that is present, whatever is wrong with it',
      () {
        expect(
          WindowsLoaderCheck.needsRedistributable(const [
            DllResolution(
              name: 'MSVCP140.dll',
              path: r'C:\e\MSVCP140.dll',
              machine: 0x014c,
            ),
          ]),
          isFalse,
        );
      },
    );

    test('is false for a missing library Windows itself ships', () {
      expect(
        WindowsLoaderCheck.needsRedistributable(const [
          DllResolution(name: 'dxgi.dll', path: null, machine: null),
        ]),
        isFalse,
      );
    });
  });

  group('report', () {
    test('lists every library with where it came from', () {
      final text = WindowsLoaderCheck.report(const [
        DllResolution(
          name: 'onnxruntime.dll',
          path: r'C:\e\onnxruntime.dll',
          machine: WindowsLoaderCheck.amd64,
        ),
        DllResolution(name: 'dbghelp.dll', path: null, machine: null),
      ]);
      expect(text, contains(r'C:\e\onnxruntime.dll'));
      expect(text, contains('64-bit'));
      expect(text, contains('dbghelp.dll'));
      expect(text, contains('not found'));
    });
  });
}

List<int> utf8Bytes(String s) => s.codeUnits;
