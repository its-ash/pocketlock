import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:theme/theme.dart';

import 'app/app_controller.dart';
import 'app/app_scope.dart';
import 'app/export_service.dart';
import 'app/import_service.dart';
import 'app/settings_store.dart';
import 'app/temp_files.dart';
import 'platform/native_bridge.dart';
import 'screens/gate.dart';
import 'vault/vault_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // cryptography_flutter registers itself: AES-GCM and PBKDF2 run natively.
  final native = NativeBridge();
  final docs = await getApplicationDocumentsDirectory();
  final vault = VaultStore(root: Directory('${docs.path}/vault'), keystore: native);
  final temp = await TempFiles.create();
  final navigatorKey = GlobalKey<NavigatorState>();
  final controller = AppController(
    vault: vault,
    settings: await SettingsStore.load(),
    native: native,
    temp: temp,
    navigatorKey: navigatorKey,
  );
  final importer = ImportService(vault: vault, native: native);
  final exporter = ExportService(vault: vault, native: native, temp: temp);

  runApp(PocketlockApp(controller: controller, importer: importer, exporter: exporter, navigatorKey: navigatorKey));
  await controller.init();
}

class PocketlockApp extends StatelessWidget {
  const PocketlockApp({
    super.key,
    required this.controller,
    required this.importer,
    required this.exporter,
    required this.navigatorKey,
  });

  final AppController controller;
  final ImportService importer;
  final ExportService exporter;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      importer: importer,
      exporter: exporter,
      child: UiApp(
        title: 'Pocketlock',
        themeMode: ThemeMode.system,
        navigatorKey: navigatorKey,
        home: const Gate(),
      ),
    );
  }
}
