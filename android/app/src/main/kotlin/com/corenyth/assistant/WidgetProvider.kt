package com.corenyth.assistant

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.widget.RemoteViews

/**
 * Passive widget: reads pending tasks straight from the app's SQLite file
 * (no Flutter engine, no model). Tap -> VoiceSessionActivity.
 */
class WidgetProvider : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) mgr.updateAppWidget(id, render(ctx))
    }

    companion object {
        fun refreshAll(ctx: Context) {
            val mgr = AppWidgetManager.getInstance(ctx)
            val ids = mgr.getAppWidgetIds(ComponentName(ctx, WidgetProvider::class.java))
            for (id in ids) mgr.updateAppWidget(id, render(ctx))
        }

        private fun render(ctx: Context): RemoteViews {
            val (count, titles) = pendingTasks(ctx)
            val v = RemoteViews(ctx.packageName, R.layout.assistant_widget)
            v.setTextViewText(R.id.widget_count, "$count pending task${if (count == 1) "" else "s"}")
            v.setTextViewText(R.id.widget_list, titles.joinToString("\n") { "☐ $it" })
            val intent = Intent(ctx, VoiceSessionActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val pi = PendingIntent.getActivity(
                ctx, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            v.setOnClickPendingIntent(R.id.widget_root, pi)
            return v
        }

        // Must match lib/data/db.dart: file "assistant.db", table tasks(title,status,due_at).
        private fun pendingTasks(ctx: Context): Pair<Int, List<String>> {
            val f = ctx.getDatabasePath("assistant.db")
            if (!f.exists()) return 0 to emptyList()
            return try {
                SQLiteDatabase.openDatabase(f.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                    val n = db.rawQuery("SELECT COUNT(*) FROM tasks WHERE status='pending'", null)
                        .use { it.moveToFirst(); it.getInt(0) }
                    val t = db.rawQuery(
                        "SELECT title FROM tasks WHERE status='pending' " +
                            "ORDER BY due_at IS NULL, due_at, id LIMIT 3", null
                    ).use { c -> generateSequence { if (c.moveToNext()) c.getString(0) else null }.toList() }
                    n to t
                }
            } catch (e: Exception) {
                0 to emptyList()
            }
        }
    }
}
