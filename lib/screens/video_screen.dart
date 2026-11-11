import 'dart:io';

import 'package:flutter/material.dart';
import 'package:theme/theme.dart';
import 'package:video_player/video_player.dart';

import '../app/app_scope.dart';
import '../vault/vault_index.dart';

/// Plays a video by decrypting it to a private temporary file. The file is
/// deleted when this screen closes and whenever the vault locks.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.item});

  final VaultItem item;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  AppScope? _scope;
  File? _file;
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scope != null) return;
    _scope = AppScope.of(context);
    _load();
  }

  Future<void> _load() async {
    final scope = _scope!;
    try {
      final file = await scope.exporter.decryptForPlayback(widget.item);
      _file = file;
      if (!mounted) return;
      final controller = VideoPlayerController.file(file);
      _controller = controller;
      await controller.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    final file = _file;
    if (file != null) _scope?.exporter.temp.release(file);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    return UiScaffold(
      appBar: UiAppBar(title: widget.item.name),
      padding: EdgeInsets.zero,
      body: Center(
        child: _error != null
            ? UiErrorState(title: 'Cannot play this video', message: 'It may use a format this phone cannot play.')
            : ready
            ? UiVideoPlayer.controller(controller, autoPlay: true, allowFullscreen: false, radius: 0)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const UiSpinner(size: 28),
                  const UiGap(UiSpace.md),
                  Text('Decrypting video', style: context.text.bodyMedium),
                ],
              ),
      ),
    );
  }
}
