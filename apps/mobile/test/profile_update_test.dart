import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_offer.dart';
import 'package:soundflow/features/profile/profile_screen.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('строка "О программе" видна всегда', (tester) async {
    final api = Api();
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        dbProvider.overrideWithValue(db),
        syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db))),
      ],
      child: const MaterialApp(home: ProfileScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('О программе'), findsOneWidget);
    await db.close();
  });
}
