import 'package:app_synchro_film/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('accueil : 4 modes, seuls les modes disponibles sont actifs',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    expect(find.text('Synchro double fichier'), findsOneWidget);
    expect(find.text('Stream app ↔ app'), findsOneWidget);
    expect(find.text('Audio seul (écran partagé)'), findsOneWidget);
    expect(find.text('Stream vers navigateur'), findsOneWidget);
    expect(find.textContaining('bientôt'), findsNWidgets(3));
    expect(find.text('Créer une session (hôte)'), findsOneWidget);
    expect(find.text('Rejoindre une session'), findsOneWidget);
  });
}
