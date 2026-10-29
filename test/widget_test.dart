import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/widgets/glass_card.dart';
import 'package:thando_sign_app/widgets/primary_button.dart';

void main() {
  testWidgets('GlassCard renders its child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: GlassCard(child: Text('ThandoSign'))),
      ),
    );

    expect(find.text('ThandoSign'), findsOneWidget);
  });

  testWidgets('PrimaryButton shows label and calls onPressed', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrimaryButton(
            label: 'Translate Now',
            onPressed: () => tapped = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Translate Now'));
    expect(tapped, isTrue);
  });
}
