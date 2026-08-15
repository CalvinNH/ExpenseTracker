import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android activity hides navigation with a transient swipe escape route',
      () async {
    final activity = await File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/MainActivity.kt',
    ).readAsString();

    expect(activity, contains('WindowInsets.Type.navigationBars()'));
    expect(
      activity,
      contains('BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE'),
    );
    expect(activity, contains('SYSTEM_UI_FLAG_IMMERSIVE_STICKY'));
    expect(activity, contains('onWindowFocusChanged'));
  });
}
