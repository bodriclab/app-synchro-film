import 'package:app_synchro_film/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('accueil : les 5 modes sont disponibles', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: HomeScreen(autoCheckUpdates: false)),
    );
    expect(find.text('Synchro double fichier'), findsOneWidget);
    expect(find.text('Stream app ↔ app'), findsOneWidget);
    expect(find.text('Audio seul (écran partagé)'), findsOneWidget);
    expect(find.text('Stream vers navigateur'), findsOneWidget);
    expect(find.text('Audio seul vers navigateur'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.textContaining('bientôt'), findsNothing);
    expect(find.text('Créer une session (hôte)'), findsOneWidget);
    expect(find.text('Rejoindre une session'), findsOneWidget);
  });
}
