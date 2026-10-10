package com.corenyth.assistant

import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

/** Small translucent window opened by the widget's Talk button; Dart renders route "/voice". */
class VoiceSessionActivity : MainActivity() {
    override fun getInitialRoute(): String = "/voice"
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent
}
