import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final builder = CBuilder.library(
      name: 'document_file_io',
      assetName: 'document_file_io.dart',
      sources: ['src/document_file_io.c'],
    );
    await builder.run(input: input, output: output);
  });
}
