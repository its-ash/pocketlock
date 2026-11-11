import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_scope.dart';
import '../app/import_service.dart';
import '../platform/native_bridge.dart';

/// Runs the import flow for a screen: pick, encrypt with progress, then offer
/// to delete the originals. The screen shows [ImportOverlay] for [progress].
class ImportRunner {
  final ValueNotifier<ImportProgress?> progress = ValueNotifier(null);

  bool _disposed = false;

  bool get running => !_disposed && progress.value != null;

  void dispose() {
    _disposed = true;
    progress.dispose();
  }

  // The screen can be closed (or the vault locked) while an import runs.
  void _set(ImportProgress? value) {
    if (!_disposed) progress.value = value;
  }

  Future<void> run(BuildContext context, String albumId) async {
    if (running) return;
    final scope = AppScope.of(context);

    final mediaOnly = await UiActionSheet.show<bool>(
      context,
      title: 'Import into the vault',
      message: 'Pocketlock encrypts a copy. You can delete the originals afterwards.',
      actions: const [
        UiSheetAction('Photos and videos', value: true, icon: Icons.photo_library_rounded),
        UiSheetAction('Files', value: false, icon: Icons.folder_rounded),
      ],
    );
    if (mediaOnly == null || !context.mounted) return;

    final List<PickedFile> picked;
    try {
      picked = await scope.controller.suppressLock(() => scope.importer.native.pick(mediaOnly: mediaOnly));
    } on KeystoreException {
      if (context.mounted) context.showToast('Could not open the picker.', status: UiStatus.danger);
      return;
    }
    if (picked.isEmpty || !context.mounted) return;

    final ImportResult result;
    _set(ImportProgress(index: 0, total: picked.length, name: picked.first.name, fraction: 0));
    try {
      result = await scope.importer.run(picked, albumId: albumId, onProgress: _set);
    } finally {
      _set(null);
    }
    if (!context.mounted) return;

    if (result.failed.isNotEmpty) {
      context.showToast(
        '${result.failed.length} of ${picked.length} could not be imported.',
        title: 'Some files failed',
        status: UiStatus.warning,
      );
    } else {
      context.showToast('Encrypted ${result.imported} ${result.imported == 1 ? 'file' : 'files'}.', status: UiStatus.success);
    }
    if (result.originals.isNotEmpty) await _offerDelete(context, scope, result.originals);
  }

  Future<void> _offerDelete(BuildContext context, AppScope scope, List<String> originals) async {
    final count = originals.length;
    final delete = await UiDialog.confirm(
      context,
      title: 'Delete the originals?',
      message:
          '$count ${count == 1 ? 'photo or video is' : 'photos and videos are'} still in your gallery. '
          'Android will ask you to confirm before it deletes them.',
      confirmLabel: 'Delete originals',
      cancelLabel: 'Keep them',
      destructive: true,
    );
    if (!delete || !context.mounted) return;

    final outcome = await scope.controller.suppressLock(() => scope.importer.native.deleteOriginals(originals));
    if (!context.mounted) return;
    switch (outcome) {
      case DeleteOutcome.deleted:
        context.showToast('Originals deleted from your gallery.', status: UiStatus.success);
      case DeleteOutcome.denied:
        context.showToast('The originals were kept.');
      case DeleteOutcome.unsupported:
        await UiDialog.alert(
          context,
          title: 'Delete them yourself',
          message:
              'Android 10 and older cannot delete them for you. Open your Gallery app and delete the originals so '
              'only the encrypted copies remain.',
        );
      case DeleteOutcome.failed:
        context.showToast('Could not delete the originals.', status: UiStatus.danger);
    }
  }
}

/// Dims the screen and shows import progress.
class ImportOverlay extends StatelessWidget {
  const ImportOverlay({super.key, required this.progress, required this.child});

  final ValueListenable<ImportProgress?> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ImportProgress?>(
      valueListenable: progress,
      child: child,
      builder: (context, p, child) => Stack(
        children: [
          child!,
          if (p != null) ...[
            ModalBarrier(color: context.colors.scrim, dismissible: false),
            Center(
              child: UiSurface(
                width: 300,
                shadow: context.shadowLg,
                child: UiColumn(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Encrypting ${p.index + 1} of ${p.total}', style: context.text.titleMedium),
                    Text(
                      p.name,
                      style: context.text.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    UiProgressBar(p.overall, showPercent: true),
                    Text('Keep Pocketlock open until this finishes.', style: context.text.bodySmall),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
