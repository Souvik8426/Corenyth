package com.corenyth.assistant

import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

/** Home-screen assistant panel. Uses the same Dart session and tools as app chat. */
class WidgetAddActivity : MainActivity() {
    override fun getInitialRoute(): String = "/voice"
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent
}
