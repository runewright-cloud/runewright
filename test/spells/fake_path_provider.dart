// SPDX-License-Identifier: GPL-3.0-or-later
//
// fake_path_provider.dart — in-memory-free, real-temp-dir fake for
// path_provider's platform interface, for tests run via plain
// `flutter test` (no real device, so there's no native documents
// directory to query). Mirrors test/identity/fake_secure_storage.dart's
// approach: install a fake platform implementation rather than mocking a
// method channel directly, since path_provider exposes a Platform
// Interface seam for exactly this.

import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  FakePathProviderPlatform(this._docsPath, this._supportPath);

  final String _docsPath;
  final String _supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;

  @override
  Future<String?> getApplicationSupportPath() async => _supportPath;
}

/// Installs a fake documents directory (for SpellAsset) and a fake
/// application-support directory (for the SRS cache, srs_cache.dart),
/// both backed by real temp directories so file I/O works unmodified.
/// Callers are responsible for deleting the returned directory in
/// `tearDown`.
Future<Directory> installFakePathProvider() async {
  final dir = await Directory.systemTemp.createTemp('runewright_spells_test_');
  final docsDir = Directory('${dir.path}/docs')..createSync();
  final supportDir = Directory('${dir.path}/support')..createSync();
  PathProviderPlatform.instance = FakePathProviderPlatform(docsDir.path, supportDir.path);
  return dir;
}
