# Pocketlock

A private, encrypted vault for your photos, videos and files.

**[Website](https://pocketlock.itsash.in)** · **[Download APK](https://github.com/its-ash/pocketlock/releases/latest/download/pocketlock.apk)** · Get it in **[Ash Store](https://store.itsash.in)**

## Features

- **PIN and fingerprint**: a 4 to 8 digit PIN, plus fingerprint unlock backed by the
  Android Keystore. Wrong PINs are delayed longer each time.
- **AES-256-GCM encryption** of every file, thumbnail and the file list. Big
  videos are encrypted in 1 MiB chunks, so they never load into memory whole.
- **Import** photos, videos and any files from the system picker. Pocketlock can
  then delete the originals from your gallery (Android 11+, the system asks you).
- **Albums, grid and viewer**: decrypted thumbnails exist in memory only. Photos
  open in a zoomable viewer, videos play from a temporary private copy that is
  deleted when you close it or the vault locks.
- **Export and share**: save back to Pictures, Movies or Downloads, share, move
  between albums or delete, with multi-select.
- **Auto-lock** immediately, after 30 seconds or after 1 minute. The window is
  hidden in recents and blocks screenshots.
- **Offline**: no account, no cloud, no analytics. The only network call is the
  update check in Settings.

**There is no recovery.** If you forget your PIN and lose your fingerprint, your
files cannot be opened by anyone, including the developer.

## Install

- **Ash Store**: install [Ash Store](https://store.itsash.in) once, then install and update Pocketlock from it.
- **APK**: download the [latest APK](https://github.com/its-ash/pocketlock/releases/latest/download/pocketlock.apk) on your phone and open it. Allow your browser to install unknown apps if Android asks.

Requires Android 8.0 (API 26) or later. Deleting originals needs Android 11;
saving files back to the gallery needs Android 10 (older versions use the share sheet).

## Develop

Needs Flutter ≥ 3.44 and the shared theme package at `../theme`.

```bash
make run      # run on a connected device
make test     # flutter analyze + flutter test
make build    # release APK
make deploy   # bump version, build, tag, push, GitHub release (see store.mk)
```

## Release

`make deploy` follows the Ash Store kit (`store.mk`, `store.json`): it bumps the
version in `pubspec.yaml`, builds, commits, tags `vX.Y.Z`, pushes, and publishes
a GitHub release with `pocketlock.apk`. Ash Store and the website pick up the new
version from that release.

## Project layout

```
lib/
├── main.dart                     # UiApp + wiring
├── crypto/
│   ├── chunk_cipher.dart         # streaming AES-256-GCM container
│   └── key_wrap.dart             # PBKDF2 PIN key, key wrap, HKDF subkeys
├── vault/
│   ├── vault_store.dart          # files on disk, keys in memory, index
│   └── vault_index.dart          # albums and items (encrypted index model)
├── app/
│   ├── app_controller.dart       # lock state, auto-lock, wrong-PIN limit
│   ├── settings_store.dart       # preferences, lockout counter
│   ├── import_service.dart       # stage, thumbnail, encrypt, wipe
│   ├── export_service.dart       # export, share, playback copies
│   └── temp_files.dart           # private decrypted copies, wiped on lock
├── platform/native_bridge.dart   # MethodChannel to Kotlin
├── widgets/                      # lazy decrypting ImageProvider, grid tile
└── screens/                      # gate, setup, lock, home, album, video, settings
android/app/src/main/kotlin/com/itsash/pocketlock/
├── MainActivity.kt               # FlutterFragmentActivity, FLAG_SECURE
├── PocketlockChannel.kt          # channel handlers, picker, delete request
├── KeystoreKeys.kt               # Keystore keys, BiometricPrompt + CryptoObject
└── MediaOps.kt                   # staging, thumbnails, MediaStore export
```

See `CLAUDE.md` for the crypto design and details.

## License

No license file is included yet.

Built by [itsash.in](https://itsash.in).
