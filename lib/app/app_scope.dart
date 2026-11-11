import 'package:flutter/widgets.dart';

import 'app_controller.dart';
import 'export_service.dart';
import 'import_service.dart';

/// Gives screens the controller and services without passing them down by hand.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.controller,
    required this.importer,
    required this.exporter,
    required super.child,
  });

  final AppController controller;
  final ImportService importer;
  final ExportService exporter;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this context');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      controller != oldWidget.controller || importer != oldWidget.importer || exporter != oldWidget.exporter;
}
