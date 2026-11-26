import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_synchro_film/ui/transfer_screen.dart';

void main() {
  testWidgets('Affichage initial de ReceiveFileScreen', (
    WidgetTester tester,
  ) async {
    // Charger l'écran dans un MaterialApp
    await tester.pumpWidget(const MaterialApp(home: ReceiveFileScreen()));

    // Vérifier la présence de l'AppBar avec le titre attendu
    expect(find.text('Recevoir un film'), findsOneWidget);

    // Vérifier qu'un seul TextField est présent
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Saisie d\'un lien invalide et affichage du message d\'erreur', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ReceiveFileScreen()));

    // Entrer un texte non valide dans le TextField
    await tester.enterText(find.byType(TextField), 'pas un lien');

    // Appuyer sur le bouton "Valider"
    await tester.tap(find.text('Valider'));

    // Laisser le framework traiter les changements d'état
    await tester.pumpAndSettle();

    // Vérifier que le message d'erreur apparaît
    expect(find.text('Lien non reconnu.'), findsOneWidget);
  });
}
