# Pocketlock (package: pocketlock / com.itsash.pocketlock)

Private, offline, encrypted vault for photos, videos and files. PIN (4 to 8
digits) or fingerprint unlock, auto-lock, FLAG_SECURE. No backend, no reset.

## Crypto design

Keys
- **VMK**: vault master key, 32 random bytes, made once. Never stored in the clear.
- **Content key** and **index key**: HKDF-SHA256 from the VMK with different
  `info` strings (`pocketlock/content/v1`, `pocketlock/index/v1`). Files and
  thumbnails use the content key; `index.enc` uses the index key.
- The VMK is stored **wrapped twice** in `vault.json`:
  1. **PIN wrap** (`pinWrap`): KEK = PBKDF2-HMAC-SHA256(PIN, random 16-byte salt,
     600,000 iterations); VMK sealed with AES-256-GCM (AAD `pocketlock/pin-wrap/v1`).
     That blob is then sealed again by a **device Keystore key** (AES-GCM, no user
     auth, non-exportable), so a copy of the vault files cannot be brute-forced
     off the phone (4 to 8 digits would otherwise be weak). Headers with fewer
     than 310,000 iterations are refused.
  2. **Biometric wrap** (`bioWrap`): VMK encrypted by a Keystore AES-256-GCM key
     with `setUserAuthenticationRequired(true)`, strong biometric only (API 30+
     `AUTH_BIOMETRIC_STRONG`, per-use), `setInvalidatedByBiometricEnrollment(true)`.
     Enroll and unlock go through `BiometricPrompt` with a `CryptoObject`, so
     the key can only be used right after a real fingerprint match. If
     fingerprints change, the key is invalidated and the wrap is dropped (PIN
     still works).
- **Change PIN** only re-wraps the VMK (new salt, new KEK). Files are untouched.

Container format (`lib/crypto/chunk_cipher.dart`)
- `"PLK1"` | file id (16 random bytes) | records. Record = `nonce(12) | ciphertext |
  tag(16)`, 1 MiB of plaintext per record (last one 0..1 MiB).
- AAD per chunk = file id | chunk index (u32 BE) | final flag. Reordering,
  dropping, appending, truncating at a chunk boundary and splicing chunks from
  another file all fail authentication. Random 96-bit nonce per chunk.
- Streaming both ways (one chunk in memory). Small values (index, thumbnails) use
  the same format through `encryptBytes` / `decryptBytes`.

On disk (app-private `getApplicationDocumentsDirectory()/vault`): `vault.json`
(public header), `index.enc` (albums, names, mime, sizes, dates), `blobs/<hex id>`,
`thumbs/<hex id>` (JPEG, encrypted). Names are random ids; nothing readable. The
index is rewritten atomically (tmp + rename). Orphans from interrupted imports
are swept at unlock. `allowBackup=false` and data-extraction rules exclude all data.

Plaintext exposure, on purpose and bounded
- Thumbnails and photos: decrypted in memory (`VaultImageProvider`), dropped on lock
  (image cache cleared).
- Import: the picked file is copied to `cache/pl_staging`, thumbnailed natively,
  encrypted, and the copy is deleted right away (also wiped at startup).
- Video, share, export: decrypted to `cache/pl_tmp/<random>/name`, deleted on
  close, on lock and at startup.
- Dart cannot guarantee wiping `String` PINs or GC'd buffers; keys are held in
  `SecretKeyData(overwriteWhenDestroyed: true)` and zeroed on lock.

Rate limit: 3rd wrong PIN gives 30 s, doubling per failure up to 1 h
(`pinLockoutFor`), kept in SharedPreferences. It is a speed bump, not the real
defense (that is the KDF + device-sealed key). It uses wall-clock time.

## Code layout

- `lib/crypto/`: `chunk_cipher.dart`, `key_wrap.dart` (pure Dart, `cryptography`;
  `cryptography_flutter` makes AES-GCM and PBKDF2 native on Android).
- `lib/vault/`: `vault_store.dart` (header, keys in memory, index, files),
  `vault_index.dart` (models).
- `lib/app/`: `AppController` (status loading/setup/locked/unlocked, lifecycle
  auto-lock, `suppressLock` around pickers/prompts/share), `SettingsStore`,
  `ImportService`, `ExportService`, `TempFiles`, `AppScope`.
- `lib/screens/`: `Gate` (root route; pushed screens are popped on lock), setup,
  lock, home (albums), album (grid, multi-select), video, settings, change PIN,
  `import_flow.dart`. UI only from `theme` (`Ui*`).
- `lib/platform/native_bridge.dart`: MethodChannel `com.itsash.pocketlock/native`:
  `setSecure`, `biometricStatus/Enroll/Unlock/Remove`, `deviceSeal/Unseal`, `pick`,
  `stage`, `wipeStaging`, `thumbnail`, `export`, `deleteOriginals`.
- Kotlin (`android/app/src/main/kotlin/com/itsash/pocketlock/`): `MainActivity`
  (FlutterFragmentActivity for BiometricPrompt; FLAG_SECURE set in `onCreate`),
  `PocketlockChannel`, `KeystoreKeys`, `MediaOps`.

Import uses `ACTION_OPEN_DOCUMENT` (multi-select; media-only filter for gallery).
Gallery originals are deleted with `MediaStore.createDeleteRequest` (API 30+, the
system shows its own confirmation); the documents URI is mapped to the MediaStore
URI. If the system needs gallery read access first, the channel asks for
`READ_MEDIA_IMAGES/VIDEO` (or `READ_EXTERNAL_STORAGE`) once and retries. Below
API 30 the app tells the user to delete originals themselves. Export to
Pictures/Movies/Downloads (`Pocketlock` folder) uses MediaStore inserts (API 29+);
below that it opens the share sheet.

## Commands

- `make run`, `make build` (release APK), `make test` (`flutter analyze` +
  `flutter test`), `make clean`.
- Tests: `test/chunk_cipher_test.dart` (round trip, wrong key, tamper, truncation,
  reorder, splice), `test/key_wrap_test.dart` (PBKDF2 vector, wrap/unwrap),
  `test/vault_store_test.dart` (end-to-end on disk with a fake Keystore),
  `test/app_logic_test.dart` (lockout, settings). Tests use few PBKDF2
  iterations; the app uses 600,000. Add a case for every crypto or format change.
- Icon: SVG sources in `assets/icon/` (`logo`, `logo_foreground`,
  `logo_background`) → `rsvg-convert -w 1024 -h 1024` to `*-1024.png`, then
  `dart run flutter_launcher_icons`.

## Conventions

- minSdk 26. UI only from the shared `theme` package (`../theme`, read
  `../theme/COMPONENTS.md`); no hardcoded colors.
- Never log PINs, keys or file names. Only network use: `UiUpdateSection` in
  Settings (`INTERNET`). No analytics or telemetry.
- Anything that opens a system screen (picker, BiometricPrompt, share sheet,
  delete confirmation) must run inside `controller.suppressLock(...)`, or the
  app would auto-lock when it goes to the background.

## Release (Ash Store)

- `store.json` (id `pocketlock`, repo its-ash/pocketlock), `store.mk`,
  `index.html` + `CNAME` (`pocketlock.itsash.in`). See
  `../ash-store/store-kit/STORE.md`.
- `make deploy` = bump version → build → commit, tag `vX.Y.Z`, push → GitHub
  release with `pocketlock.apk` → topics, homepage, Pages. Never create releases,
  tags or asset names by hand. Build releases on the Mac that signed earlier
  releases, or updates will not install over existing copies.
- Do not edit `store.mk` here. Edit `../ash-store/store-kit/store.mk`, then run
  `make store-sync` at the workspace root.
