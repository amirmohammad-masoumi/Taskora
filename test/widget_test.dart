// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:taskora/main.dart';

void main() {
  test('Todo keeps reminder details when stored locally', () {
    final reminder = DateTime(2026, 11, 16, 9, 30);
    final todo = Todo(
      id: 'reminder-test',
      title: 'Schedule notification',
      date: reminder,
      remind: true,
      reminder: reminder,
    );

    final restored = Todo.fromJson(todo.toJson());
    expect(restored.remind, isTrue);
    expect(restored.reminder, reminder);
  });
}
