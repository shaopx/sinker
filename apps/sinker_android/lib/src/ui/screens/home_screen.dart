import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sinker_core/sinker_core.dart';

import '../../service/receiver_service.dart';
import '../../state/transfer_state.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _state = TransferState();
  ReceiverService? _service;

  @override
  void dispose() {
    _service?.stop();
    super.dispose();
  }

  /// Request storage permission on Android 11+ (MANAGE_EXTERNAL_STORAGE)
  /// or WRITE_EXTERNAL_STORAGE on older versions.
  Future<bool> _requestStoragePermission() async {
    // Android 11+ needs MANAGE_EXTERNAL_STORAGE for /sdcard/Download/
    if (await Permission.manageExternalStorage.isGranted) return true;

    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;

    // Fallback: try legacy WRITE_EXTERNAL_STORAGE (Android ≤10)
    final writeStatus = await Permission.storage.request();
    if (writeStatus.isGranted) return true;

    // Permission denied — show dialog
    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('存储权限被拒绝'),
          content: const Text(
            '需要"管理所有文件"权限才能保存到 Downloads 目录。\n\n'
            '请在系统设置 → 应用 → Sinker → 权限 中手动开启。',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                openAppSettings();
              },
              child: const Text('去设置'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        ),
      );
    }
    return false;
  }

  Future<void> _toggleService() async {
    if (_state.isListening) {
      await _service?.stop();
      _state.setListening(false);
      _state.updateStatus('Stopped');
    } else {
      // Request storage permission before accessing /sdcard/Download/
      final granted = await _requestStoragePermission();
      if (!granted) {
        _state.updateStatus('需要存储权限才能运行');
        return;
      }

      // Save to public Download directory so user can easily find files
      const saveDir = '/sdcard/Download/sinker';
      // Ensure directory exists
      await Directory(saveDir).create(recursive: true);

      _service = ReceiverService(
        port: defaultPort,
        password: defaultPassword,
        saveDir: saveDir,
      );
      _service!.onStatusChanged = (msg) => _state.updateStatus(msg);
      _service!.onProgress = (p) => _state.updateProgress(p);
      _service!.onTransferComplete = (name, ok) {
        _state.addHistoryEntry(name, ok);
      };
      _service!.onLog = (level, message) {
        _state.addLog(level, message);
      };
      _state.addLog('INFO', 'Service starting on port $defaultPort, saveDir=$saveDir');

      _state.setListening(true);
      // Start listening in background
      _service!.start().catchError((e) {
        _state.updateStatus('Error: $e');
        _state.setListening(false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sinker'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Status card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        Icon(
                          _state.isListening
                              ? Icons.cloud_download
                              : Icons.cloud_off,
                          size: 64,
                          color: _state.isListening
                              ? Colors.green
                              : Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _state.isListening ? 'Listening' : 'Stopped',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _state.status,
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        if (_state.isListening) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Port: $defaultPort',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Progress indicator
                if (_state.currentProgress != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _state.currentProgress!.fileName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _state.currentProgress!.percentage,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _state.currentProgress!.toString(),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Start/Stop button
                FilledButton.icon(
                  onPressed: _toggleService,
                  icon: Icon(
                    _state.isListening ? Icons.stop : Icons.play_arrow,
                  ),
                  label: Text(_state.isListening ? 'Stop' : 'Start Receiving'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor:
                        _state.isListening ? Colors.red : null,
                  ),
                ),
                const SizedBox(height: 24),

                // Transfer history (compact)
                if (_state.history.isNotEmpty) ...[
                  Text(
                    'Recent Transfers',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 80,
                    child: ListView.builder(
                      itemCount: _state.history.length,
                      itemBuilder: (context, index) {
                        final entry = _state.history[index];
                        return ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: Icon(
                            entry.success
                                ? Icons.check_circle
                                : Icons.error,
                            color: entry.success ? Colors.green : Colors.red,
                            size: 18,
                          ),
                          title: Text(
                            entry.fileName,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${entry.timestamp.hour}:${entry.timestamp.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // Log panel — critical for diagnosing OOM / large file issues
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Logs (${_state.logs.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    TextButton.icon(
                      onPressed: _state.logs.isEmpty
                          ? null
                          : () => _state.clearLogs(),
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: const Text('Clear'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: _state.logs.isEmpty
                        ? const Center(
                            child: Text(
                              'No logs yet. Start the receiver to see activity.',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          )
                        : ListView.builder(
                            reverse: false,
                            itemCount: _state.logs.length,
                            itemBuilder: (context, index) {
                              final log = _state.logs[index];
                              final color = switch (log.level) {
                                'ERROR' => Colors.redAccent,
                                'WARN' => Colors.orangeAccent,
                                'INFO' => Colors.lightGreenAccent,
                                'DEBUG' => Colors.white70,
                                _ => Colors.white,
                              };
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 1,
                                ),
                                child: RichText(
                                  text: TextSpan(
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: Colors.white,
                                    ),
                                    children: [
                                      TextSpan(
                                        text: '${log.timeLabel} ',
                                        style: const TextStyle(
                                          color: Colors.white38,
                                        ),
                                      ),
                                      TextSpan(
                                        text:
                                            '${log.level.padRight(5)} ',
                                        style: TextStyle(
                                          color: color,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      TextSpan(
                                        text: log.message,
                                        style: TextStyle(color: color),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
