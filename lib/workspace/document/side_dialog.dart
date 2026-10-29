import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

/// Asks which side a repertoire chapter is for: two buttons, White and
/// Black, and the answer is the side, or null when the question was
/// dismissed. Asked once per file, when the file does not say.
Future<Side?> showSideDialog(BuildContext context, {required String chapter}) =>
    showDialog<Side>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Which side is $chapter for?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(Side.white),
            child: const Text('White'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(Side.black),
            child: const Text('Black'),
          ),
        ],
      ),
    );
