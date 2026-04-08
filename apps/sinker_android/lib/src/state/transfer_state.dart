import 'package:flutter/foundation.dart';
import 'package:sinker_core/sinker_core.dart';

/// Transfer history entry.
class TransferEntry {
  final String fileName;
  final bool success;
  final DateTime timestamp;

  TransferEntry({
    required this.fileName,
    required this.success,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Single log line shown in the UI log panel.
class LogEntry {
  final String level; // INFO / DEBUG / WARN / ERROR
  final String message;
  final DateTime timestamp;

  LogEntry({
    required this.level,
    required this.message,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  String get timeLabel {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

/// Application state managed via ChangeNotifier.
class TransferState extends ChangeNotifier {
  static const int _maxLogs = 500;

  bool _isListening = false;
  String _status = 'Stopped';
  TransferProgress? _currentProgress;
  final List<TransferEntry> _history = [];
  final List<LogEntry> _logs = [];

  bool get isListening => _isListening;
  String get status => _status;
  TransferProgress? get currentProgress => _currentProgress;
  List<TransferEntry> get history => List.unmodifiable(_history);
  List<LogEntry> get logs => List.unmodifiable(_logs);

  void addLog(String level, String message) {
    _logs.insert(0, LogEntry(level: level, message: message));
    if (_logs.length > _maxLogs) {
      _logs.removeRange(_maxLogs, _logs.length);
    }
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void setListening(bool value) {
    _isListening = value;
    notifyListeners();
  }

  void updateStatus(String status) {
    _status = status;
    notifyListeners();
  }

  void updateProgress(TransferProgress progress) {
    _currentProgress = progress;
    notifyListeners();
  }

  void clearProgress() {
    _currentProgress = null;
    notifyListeners();
  }

  void addHistoryEntry(String fileName, bool success) {
    _history.insert(0, TransferEntry(fileName: fileName, success: success));
    _currentProgress = null;
    notifyListeners();
  }
}
