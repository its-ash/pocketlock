import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_scope.dart';
import '../app/export_service.dart';
import '../vault/vault_index.dart';
import '../widgets/item_tile.dart';
import '../widgets/vault_image.dart';
import 'import_flow.dart';
import 'video_screen.dart';

/// Items of one album as a grid, with multi-select.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({super.key, required this.albumId});

  final String albumId;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  final ImportRunner _import = ImportRunner();
  final Set<String> _selected = {};
  bool _working = false;

  bool get _selecting => _selected.isNotEmpty;

  @override
  void dispose() {
    _import.dispose();
    super.dispose();
  }

  void _toggle(VaultItem item) {
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  void _open(VaultItem item, List<VaultItem> all) {
    if (_selecting) return _toggle(item);
    final vault = AppScope.of(context).controller.vault;
    switch (item.kind) {
      case VaultKind.photo:
        final photos = [for (final i in all) if (i.kind == VaultKind.photo) i];
        UiImageViewer.show(
          context,
          images: [for (final p in photos) VaultImageProvider(vault, p.id)],
          initialIndex: photos.indexWhere((p) => p.id == item.id),
        );
      case VaultKind.video:
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoScreen(item: item)));
      case VaultKind.file:
        _openFile(item);
    }
  }

  Future<void> _openFile(VaultItem item) async {
    final action = await UiActionSheet.show<String>(
      context,
      title: item.name,
      message: UiFormat.bytes(item.size),
      actions: const [
        UiSheetAction('Open or share', value: 'share', icon: Icons.ios_share_rounded),
        UiSheetAction('Save to Downloads', value: 'export', icon: Icons.download_rounded),
      ],
    );
    if (action == 'share') await _share([item]);
    if (action == 'export') await _export([item]);
  }

  /// Runs [job] with a busy overlay and a friendly error.
  Future<void> _busy(Future<void> Function() job, {String failure = 'That did not work.'}) async {
    setState(() => _working = true);
    try {
      await job();
    } catch (_) {
      if (mounted) context.showToast(failure, status: UiStatus.danger);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  List<VaultItem> _selectedItems() {
    final vault = AppScope.of(context).controller.vault;
    return [for (final id in _selected) ?vault.item(id)];
  }

  Future<void> _share(List<VaultItem> items) async {
    final scope = AppScope.of(context);
    await _busy(
      () => scope.controller.suppressLock(() => scope.exporter.share(items)),
      failure: 'Could not share.',
    );
  }

  Future<void> _export(List<VaultItem> items) async {
    final scope = AppScope.of(context);
    await _busy(() async {
      final outcome = await scope.controller.suppressLock(() => scope.exporter.export(items));
      if (!mounted) return;
      if (outcome == ExportOutcome.done) {
        final noun = items.length == 1 ? 'file' : 'files';
        context.showToast('Saved ${items.length} $noun to Pictures, Movies or Downloads (Pocketlock folder).', status: UiStatus.success);
      }
      setState(_selected.clear);
    }, failure: 'Could not save the files.');
  }

  Future<void> _delete(List<VaultItem> items) async {
    final vault = AppScope.of(context).controller.vault;
    final sure = await UiDialog.confirm(
      context,
      title: 'Delete ${items.length} ${items.length == 1 ? 'item' : 'items'}?',
      message: 'They are removed from the vault for good. There is no trash and no way to get them back.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!sure || !mounted) return;
    await _busy(() async {
      await vault.deleteItems([for (final i in items) i.id]);
      setState(_selected.clear);
    }, failure: 'Could not delete.');
  }

  Future<void> _move(List<VaultItem> items) async {
    final vault = AppScope.of(context).controller.vault;
    final target = await UiActionSheet.show<String>(
      context,
      title: 'Move to album',
      actions: [
        for (final a in vault.albums)
          UiSheetAction(a.name, value: a.id, icon: Icons.folder_rounded, enabled: a.id != widget.albumId),
      ],
    );
    if (target == null || !mounted) return;
    await _busy(() async {
      await vault.moveItems([for (final i in items) i.id], target);
      setState(_selected.clear);
    }, failure: 'Could not move.');
  }

  Future<void> _rename() async {
    final vault = AppScope.of(context).controller.vault;
    final current = vault.albums.firstWhere((a) => a.id == widget.albumId);
    final name = await UiDialog.prompt(
      context,
      title: 'Rename album',
      label: 'Name',
      initialValue: current.name,
      validator: (value) => value.trim().isEmpty ? 'Enter a name' : null,
    );
    if (name == null) return;
    await vault.renameAlbum(widget.albumId, name);
  }

  Future<void> _deleteAlbum() async {
    final vault = AppScope.of(context).controller.vault;
    final sure = await UiDialog.confirm(
      context,
      title: 'Delete this album?',
      message: 'Its items are not deleted. They move to Unsorted.',
      confirmLabel: 'Delete album',
      destructive: true,
    );
    if (!sure || !mounted) return;
    await vault.deleteAlbum(widget.albumId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final vault = scope.controller.vault;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: ImportOverlay(
        progress: _import.progress,
        child: ListenableBuilder(
          listenable: vault,
          builder: (context, _) {
            final album = vault.albums.where((a) => a.id == widget.albumId).firstOrNull;
            final items = vault.itemsIn(widget.albumId);
            _selected.removeWhere((id) => vault.item(id) == null);
            return UiLoadingOverlay(
              loading: _working,
              child: UiScaffold(
                padding: const EdgeInsets.fromLTRB(UiSpace.sm, UiSpace.sm, UiSpace.sm, 0),
                appBar: _selecting ? _selectionBar(items) : _albumBar(album?.name ?? 'Album', items.length, album?.isDefault ?? true),
                fab: _selecting ? null : UiFab(Icons.add_rounded, tooltip: 'Import', onPressed: () => _import.run(context, widget.albumId)),
                bottomBar: _selecting ? _actionBar() : null,
                body: items.isEmpty
                    ? UiEmptyState(
                        icon: Icons.photo_library_outlined,
                        title: 'Nothing here yet',
                        message: 'Tap + to import photos, videos or files into this album.',
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 128,
                          mainAxisSpacing: UiSpace.xs,
                          crossAxisSpacing: UiSpace.xs,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          return ItemTile(
                            key: ValueKey(item.id),
                            vault: vault,
                            item: item,
                            selected: _selected.contains(item.id),
                            selecting: _selecting,
                            onTap: () => _open(item, items),
                            onLongPress: () => _toggle(item),
                          );
                        },
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  PreferredSizeWidget _albumBar(String title, int count, bool isDefault) {
    return UiAppBar(
      title: title,
      subtitle: '$count ${count == 1 ? 'item' : 'items'}',
      actions: [
        if (!isDefault)
          UiMenuButton<String>(
            items: const [
              UiMenuItem('rename', 'Rename album', icon: Icons.edit_rounded),
              UiMenuItem('delete', 'Delete album', icon: Icons.delete_outline_rounded, destructive: true),
            ],
            onSelected: (v) => v == 'rename' ? _rename() : _deleteAlbum(),
          ),
      ],
    );
  }

  PreferredSizeWidget _selectionBar(List<VaultItem> items) {
    return UiAppBar(
      title: '${_selected.length} selected',
      leading: UiIconButton(Icons.close_rounded, tooltip: 'Cancel selection', onPressed: () => setState(_selected.clear)),
      actions: [
        UiIconButton(
          Icons.select_all_rounded,
          tooltip: 'Select all',
          onPressed: () => setState(() => _selected.addAll(items.map((i) => i.id))),
        ),
      ],
    );
  }

  Widget _actionBar() {
    return UiBottomBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          UiIconButton(Icons.download_rounded, tooltip: 'Save to device', onPressed: () => _export(_selectedItems())),
          UiIconButton(Icons.ios_share_rounded, tooltip: 'Share', onPressed: () => _share(_selectedItems())),
          UiIconButton(Icons.drive_file_move_rounded, tooltip: 'Move to album', onPressed: () => _move(_selectedItems())),
          UiIconButton(
            Icons.delete_outline_rounded,
            tooltip: 'Delete',
            status: UiStatus.danger,
            onPressed: () => _delete(_selectedItems()),
          ),
        ],
      ),
    );
  }
}
