import 'dart:async' show Timer;

import 'package:core_management/core_management.dart';
import 'package:flutter/material.dart';

/// A widget that shows a loading overlay on top of its child.
///
/// This widget should be used within the [MaterialApp.builder] to ensure proper
/// theming and other MaterialApp features work correctly.
///
/// Example usage in MaterialApp:
/// ```dart
/// MaterialApp.router(
///   routerConfig: _config,
///   title: 'My App',
///   builder: (context, child) {
///     return LoadingOverlay(
///       child: child!,
///     );
///   },
/// )
/// ```
class LoadingOverlay<T> extends StatefulWidget {
  /// Creates a [LoadingOverlay] widget.
  ///
  /// The [child] parameter must not be null. This is typically the widget tree
  /// that should be displayed under the loading overlay.
  const LoadingOverlay({super.key, required this.child});

  /// The widget below this widget in the tree.
  ///
  /// This widget will be displayed normally, and the loading overlay will be
  /// shown on top of it when loading is active.
  ///
  /// When used with [MaterialApp.builder], this will be the child provided
  /// by the builder, which already has all the proper theming and localization
  /// applied.
  final Widget child;

  @override
  State<LoadingOverlay> createState() => _LoadingOverlayState();
}

class _LoadingOverlayState extends State<LoadingOverlay> {
  final GlobalKey<OverlayState> _overlayKey = GlobalKey<OverlayState>();
  final service = BaseCoreService.instance.loadingService;
  late final controller = service.controller;

  OverlayEntry? entry;

  @override
  void initState() {
    controller.addListener(_listener);
    super.initState();
  }

  void _listener() {
    if (mounted) {
      switch (controller.state) {
        case ButterflyLoadingState.idle:
          if (entry != null) {
            entry!.remove();
            entry = null;
          }

          break;
        //   completed same as loading for now
        case ButterflyLoadingState.completed:
        case ButterflyLoadingState.loading:
          if (entry == null) {
            entry = OverlayEntry(
              builder: (context) => AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    return service.loadingWidget(controller.data);
                  }),
            );
            _overlayKey.currentState?.insert(entry!);
          }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(
      key: _overlayKey,
      initialEntries: [
        OverlayEntry(builder: (context) => widget.child),
      ],
    );
  }

  @override
  void dispose() {
    controller.removeListener(_listener);
    super.dispose();
  }
}

/// A controller that manages the state of a loading operation.
///
/// This controller is used to show and hide loading indicators throughout the app.
/// It automatically handles the transition from loading to completed states and
/// provides a way to associate data with the loading operation.
///
/// The generic type parameter [T] represents the type of data that can be
/// associated with the loading operation.
///
/// Example usage:
/// ```dart
/// final controller = ButterflyLoadingController<String>();
///
/// // Show loading with optional data
/// controller.state = ButterflyLoadingState.loading;
/// controller.data = 'Loading user profile...';
///
/// // When operation completes
/// controller.state = ButterflyLoadingState.completed;
/// ```
class ButterflyLoadingController<T> extends ChangeNotifier {
  /// Timer used for automatically transitioning from completed to idle state
  Timer? _timer;

  /// The current state of the loading operation
  ButterflyLoadingState _state = ButterflyLoadingState.idle;

  /// The duration to wait before automatically transitioning from completed to idle state
  ///
  /// Defaults to [kThemeAnimationDuration] for smooth transitions
  final Duration duration = kThemeAnimationDuration;

  /// Optional data associated with the current loading operation
  T? _data;

  ButterflyLoadingState get state => _state;

  set state(ButterflyLoadingState value) {
    if (_state != value) {
      if (value == ButterflyLoadingState.completed) {
        if (_timer?.isActive ?? false) _timer?.cancel();
        _timer = Timer(
          duration,
          () {
            _state = ButterflyLoadingState.idle;
            notifyListeners();
          },
        );
      } else {
        _changeState(value);
      }
    }
  }

  void _changeState(ButterflyLoadingState value) {
    _state = value;
    notifyListeners();
  }

  T? get data => _data;

  set data(T? value) {
    notifyListeners();
  }
}

enum ButterflyLoadingState { idle, loading, completed }
