import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Dialog for downloading games for analysis
/// Allows user to select platform, username, and date range
class AnalysisDownloadDialog extends StatefulWidget {
  final String? chesscomUsername;
  final String? lichessUsername;

  const AnalysisDownloadDialog({
    super.key,
    this.chesscomUsername,
    this.lichessUsername,
  });

  @override
  State<AnalysisDownloadDialog> createState() => _AnalysisDownloadDialogState();
}

class _AnalysisDownloadDialogState extends State<AnalysisDownloadDialog> {
  String _selectedPlatform = 'chesscom';
  late TextEditingController _usernameController;
  late TextEditingController _monthsController;
  int _monthsBack = 3;

  @override
  void initState() {
    super.initState();
    // Prefill with appropriate username based on default platform
    final initialUsername = widget.chesscomUsername ?? widget.lichessUsername ?? '';
    _usernameController = TextEditingController(text: initialUsername);
    _monthsController = TextEditingController(text: _monthsBack.toString());

    // Default to platform that has a username set
    if (widget.chesscomUsername != null && widget.chesscomUsername!.isNotEmpty) {
      _selectedPlatform = 'chesscom';
    } else if (widget.lichessUsername != null && widget.lichessUsername!.isNotEmpty) {
      _selectedPlatform = 'lichess';
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _monthsController.dispose();
    super.dispose();
  }

  void _onPlatformChanged(String? platform) {
    if (platform == null) return;

    setState(() {
      _selectedPlatform = platform;
      // Update username field when platform changes
      if (platform == 'chesscom' && widget.chesscomUsername != null) {
        _usernameController.text = widget.chesscomUsername!;
      } else if (platform == 'lichess' && widget.lichessUsername != null) {
        _usernameController.text = widget.lichessUsername!;
      }
    });
  }

  void _onMonthsChanged(double value) {
    setState(() {
      _monthsBack = value.round();
      _monthsController.text = _monthsBack.toString();
    });
  }

  void _onMonthsTextChanged(String value) {
    final months = int.tryParse(value);
    if (months != null && months >= 1 && months <= 24) {
      setState(() {
        _monthsBack = months;
      });
    }
  }

  void _onDownload() {
    final username = _usernameController.text.trim();

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a username'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Validate months
    if (_monthsBack < 1 || _monthsBack > 24) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid number of months (1-24)'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Return platform, username, and months
    Navigator.of(context).pop({
      'platform': _selectedPlatform,
      'username': username,
      'monthsBack': _monthsBack,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download Games for Analysis'),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select platform, enter username, and choose date range:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),

            // Platform selection
            RadioListTile<String>(
              title: const Text('Chess.com'),
              subtitle: const Text('Download games (no bullet)'),
              value: 'chesscom',
              groupValue: _selectedPlatform,
              onChanged: _onPlatformChanged,
            ),
            RadioListTile<String>(
              title: const Text('Lichess'),
              subtitle: const Text('Download games (no bullet)'),
              value: 'lichess',
              groupValue: _selectedPlatform,
              onChanged: _onPlatformChanged,
            ),

            const SizedBox(height: 16),

            // Username input
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(
                labelText: 'Username',
                hintText: 'Enter username',
                helperText: _selectedPlatform == 'chesscom'
                    ? 'Your Chess.com username'
                    : 'Your Lichess username',
                border: const OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 24),

            // Date range selector
            const Text(
              'Date Range',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Slider(
                        value: _monthsBack.toDouble(),
                        min: 1,
                        max: 24,
                        divisions: 23,
                        label: '$_monthsBack month${_monthsBack == 1 ? '' : 's'}',
                        onChanged: _onMonthsChanged,
                      ),
                      Center(
                        child: Text(
                          'Last $_monthsBack month${_monthsBack == 1 ? '' : 's'}',
                          style: TextStyle(color: Colors.grey[700]),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 70,
                  child: TextField(
                    controller: _monthsController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Months',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    onChanged: _onMonthsTextChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Download games from the last 1-24 months',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _onDownload,
          child: const Text('Download'),
        ),
      ],
    );
  }
}
