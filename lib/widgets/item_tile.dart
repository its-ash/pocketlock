import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../vault/vault_index.dart';
import '../vault/vault_store.dart';
import 'vault_image.dart';

/// Grid cell for one vault item: decrypted thumbnail (in memory), a play
/// badge for videos, a file icon for other files, and a selection check.
class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.vault,
    required this.item,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final VaultStore vault;
  final VaultItem item;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: item.name,
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: UiRadius.all(UiRadius.sm),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: c.surfaceMuted, child: _content(context)),
              if (item.kind == VaultKind.video)
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: c.surfaceInverse.withAlpha(150), shape: BoxShape.circle),
                    child: Padding(
                      padding: const EdgeInsets.all(UiSpace.xs),
                      child: Icon(Icons.play_arrow_rounded, color: c.onSurfaceInverse, size: 24),
                    ),
                  ),
                ),
              if (selected) ColoredBox(color: c.accent.withAlpha(70)),
              if (selecting)
                Positioned(
                  top: UiSpace.xs,
                  right: UiSpace.xs,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected ? c.accent : c.surface.withAlpha(180),
                      shape: BoxShape.circle,
                      border: Border.all(color: selected ? c.accent : c.borderStrong),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: selected
                          ? Icon(Icons.check_rounded, size: 16, color: c.onAccent)
                          : const SizedBox.square(dimension: 16),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (item.hasThumb) {
      return Image(
        image: VaultImageProvider(vault, item.id, thumbnail: true),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => _fileFace(context),
      );
    }
    return _fileFace(context);
  }

  Widget _fileFace(BuildContext context) {
    final icon = switch (item.kind) {
      VaultKind.photo => Icons.image_rounded,
      VaultKind.video => Icons.videocam_rounded,
      VaultKind.file => Icons.insert_drive_file_rounded,
    };
    return Padding(
      padding: const EdgeInsets.all(UiSpace.sm),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: context.colors.textMuted, size: 32),
          const UiGap(UiSpace.xs),
          Text(
            item.name,
            style: context.text.labelSmall?.copyWith(color: context.colors.textMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
