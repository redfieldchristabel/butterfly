/// Entry point of the Cocoon DevTools extension.
///
/// The [DevToolsExtension] wrapper initializes the managers and the
/// DevTools-to-extension connection; [CocoonInspectorApp] renders the
/// inspector itself.
library;

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:material_ui/material_ui.dart';

import 'src/app.dart';

void main() {
  runApp(const CocoonDevToolsExtension());
}

/// The root widget DevTools embeds in its extension iFrame.
class CocoonDevToolsExtension extends StatelessWidget {
  const CocoonDevToolsExtension({super.key});

  @override
  Widget build(BuildContext context) {
    return const DevToolsExtension(child: CocoonInspectorApp());
  }
}
