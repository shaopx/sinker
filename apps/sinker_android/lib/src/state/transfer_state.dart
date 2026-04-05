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

/// Application state managed via ChangeNotifier.
class TransferState extends ChangeNotifier {
  bool _isListening = false;
  String _status = 'Stopped';
  TransferProgress? _currentProgress;
  final List<TransferEntry> _history = [];

  bool get isListening => _isListening;
  String get status => _status;
  TransferProgress? get currentProgress => _currentProgress;
  List<TransferEntry> get history => List.unmodifiable(_history);

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
