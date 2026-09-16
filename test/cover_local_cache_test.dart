import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/cover_local_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoverLocalCache.contentUriForPath', () {
    test('exposes generated cover files through a content URI', () async {
      final uri = await CoverLocalCache.contentUriForPath(
        '/cache/covers_v2/0123456789abcdef0123456789abcdef01234567.img',
      );

      expect(uri, isNotNull);
      expect(uri!.scheme, 'content');
      expect(uri.authority, endsWith('.coverart'));
      expect(uri.pathSegments, <String>[
        '0123456789abcdef0123456789abcdef01234567.img',
      ]);
    });

    test('does not expose files outside the generated cover cache', () async {
      final uri = await CoverLocalCache.contentUriForPath(
        '/cache/private/notes.txt',
      );

      expect(uri, isNull);
    });
  });

  group('CoverLocalCache freshness', () {
    test('does not refresh before five days', () {
      final now = DateTime(2026, 9, 14, 12);

      expect(
        CoverLocalCache.isCacheFresh(
          modifiedAt: now.subtract(const Duration(days: 4, hours: 23)),
          now: now,
        ),
        isTrue,
      );
    });

    test('refreshes at the five day boundary', () {
      final now = DateTime(2026, 9, 14, 12);

      expect(
        CoverLocalCache.isCacheFresh(
          modifiedAt: now.subtract(const Duration(days: 5)),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
