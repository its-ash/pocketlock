import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_scope.dart';
import '../vault/vault_index.dart';
import '../vault/vault_store.dart';
import '../widgets/vault_image.dart';
import 'album_screen.dart';
import 'import_flow.dart';
import 'settings_screen.dart';

/// The unlocked vault: albums, import, settings, lock.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImportRunner _import = ImportRunner();

  @override
  void dispose() {
    _import.dispose();
    super.dispose();
  }

  Future<void> _newAlbum(VaultStore vault) async {
    final name = await UiDialog.prompt(
      context,
      title: 'New album',
      label: 'Name',
      confirmLabel: 'Create',
      validator: (value) => value.trim().isEmpty ? 'Enter a name' : null,
    );
    if (name == null) return;
    await vault.addAlbum(name);
  }

  void _open(VaultAlbum album) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: album.id)));
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final vault = scope.controller.vault;
    return ImportOverlay(
      progress: _import.progress,
      child: ListenableBuilder(
        listenable: vault,
        builder: (context, _) {
          final albums = vault.albums;
          return UiScaffold(
            appBar: UiAppBar(
              title: 'Pocketlock',
              subtitle: '${vault.itemCount} ${vault.itemCount == 1 ? 'item' : 'items'}, encrypted',
              back: false,
              actions: [
                UiIconButton(Icons.create_new_folder_rounded, tooltip: 'New album', onPressed: () => _newAlbum(vault)),
                UiIconButton(Icons.lock_rounded, tooltip: 'Lock now', onPressed: scope.controller.lock),
                UiIconButton(
                  Icons.settings_rounded,
                  tooltip: 'Settings',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
                ),
              ],
            ),
            fab: UiFab(
              Icons.add_rounded,
              label: 'Import',
              onPressed: () => _import.run(context, VaultAlbum.defaultId),
            ),
            scrollable: true,
            body: vault.itemCount == 0 && albums.length == 1
                ? Padding(
                    padding: const EdgeInsets.only(top: UiSpace.xxxl),
                    child: UiEmptyState(
                      icon: Icons.lock_outline_rounded,
                      title: 'Your vault is empty',
                      message: 'Import photos, videos or files. They are encrypted and only you can open them.',
                      action: UiButton(
                        'Import',
                        icon: Icons.add_rounded,
                        onPressed: () => _import.run(context, VaultAlbum.defaultId),
                      ),
                    ),
                  )
                : UiListGroup(
                    header: 'Albums',
                    children: [
                      for (final album in albums) _AlbumTile(vault: vault, album: album, onTap: () => _open(album)),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.vault, required this.album, required this.onTap});

  final VaultStore vault;
  final VaultAlbum album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final items = vault.itemsIn(album.id);
    final cover = items.where((i) => i.hasThumb).firstOrNull;
    return UiListTile(
      album.name,
      subtitle: '${items.length} ${items.length == 1 ? 'item' : 'items'}',
      leading: cover == null
          ? const UiIconBox(Icons.folder_rounded)
          : ClipRRect(
              borderRadius: UiRadius.all(UiRadius.sm),
              child: Image(
                image: VaultImageProvider(vault, cover.id, thumbnail: true),
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => const UiIconBox(Icons.folder_rounded),
              ),
            ),
      chevron: true,
      onTap: onTap,
    );
  }
}
