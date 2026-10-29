import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/widgets/app_logo.dart';

void main() {
  // Run with `flutter test --update-goldens` to (re)generate the PNG used
  // for the launcher icon — keeps the shipped icon identical to the widget.
  testWidgets('AppLogo golden', (tester) async {
    // Widget tests don't ship icon fonts — MaterialIcons glyphs would draw
    // as empty boxes, so load the real font from the Flutter SDK first.
    await tester.runAsync(() async {
      const fontPath =
          r'C:\Users\tanak\develop\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf';
      final bytes = await File(fontPath).readAsBytes();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    });

    tester.view.physicalSize = const Size(1024, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Capture only the widget — corners outside the rounded square stay
    // transparent so the launcher icon is pixel-identical to the logo.
    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Center(child: AppLogo(size: 1024)),
      ),
    );
    await expectLater(
      find.byType(AppLogo),
      matchesGoldenFile('goldens/app_logo.png'),
    );
  });
}
