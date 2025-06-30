import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart' show Widget;

import '../../services/base_loading.dart' show BaseLoadingService;

class DefaultLoadingService extends BaseLoadingService {
  @override
  Widget loadingWidget<T>(T data) => CupertinoActivityIndicator();
}
