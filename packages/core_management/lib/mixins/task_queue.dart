import 'dart:collection';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/widgets.dart';

mixin TaskQueueMixin<T extends StatefulWidget> on State<T> {
  final Queue<VoidCallback> _taskQueue = Queue<VoidCallback>();
  bool _isProcessing = false;

  /// Enqueues a callback to be executed after the current build phase.
  /// Ensures the widget is still mounted before execution.
  void enqueue(VoidCallback callback) {
    _taskQueue.add(() {
      if (!mounted) return;
      callback();
    });

    if (!_isProcessing) {
      _processQueue();
    }
  }

  void _processQueue() {
    if (_taskQueue.isEmpty) {
      _isProcessing = false;
      return;
    }

    _isProcessing = true;

    final schedulerPhase = SchedulerBinding.instance.schedulerPhase;

    if (schedulerPhase == SchedulerPhase.idle ||
        schedulerPhase == SchedulerPhase.postFrameCallbacks) {
      // Not building: run immediately.
      final task = _taskQueue.removeFirst();
      task();
      _processQueue();
    } else {
      // Building or layout: defer.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;

        final task = _taskQueue.removeFirst();
        task();
        _processQueue();
      });
    }
  }

  @override
  void dispose() {
    _taskQueue.clear();
    super.dispose();
  }
}
