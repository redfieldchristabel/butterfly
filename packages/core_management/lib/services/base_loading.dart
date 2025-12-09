import 'package:core_management/widgets/loading_overlay.dart';
import 'package:flutter/material.dart';

abstract class BaseLoadingService {
  final ButterflyLoadingController controller = ButterflyLoadingController();

  Widget loadingWidget<T>(T data);
}
