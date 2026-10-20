package com.corenyth.assistant

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.RemoteViews

open class WidgetProvider : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        ids.forEach { mgr.updateAppWidget(it, render(ctx, it)) }
    }
    override fun onAppWidgetOptionsChanged(ctx: Context, mgr: AppWidgetManager, id: Int, options: Bundle) {
        mgr.updateAppWidget(id, render(ctx, id))
    }
    override fun onReceive(ctx: Context, intent: Intent) {
        super.onReceive(ctx, intent)
        if (intent.action == COMPLETE) {
            val id = intent.getLongExtra("task", -1)
            if (id <= 0) return
            val pending = goAsync()
            Proactive.run(ctx, listOf("widgetDone", id)) { pending.finish() }
        }
    }
    companion object {
        const val COMPLETE = "com.corenyth.assistant.WIDGET_COMPLETE"
        private val providers = listOf(WidgetProvider::class.java, CompactWidgetProvider::class.java)
        fun count(ctx: Context): Int = providers.sumOf {
            AppWidgetManager.getInstance(ctx).getAppWidgetIds(ComponentName(ctx, it)).size
        }
        fun requestPin(ctx: Context, compact: Boolean = false): Boolean {
            if (Build.VERSION.SDK_INT < 26) return false
            val mgr = AppWidgetManager.getInstance(ctx)
            if (!mgr.isRequestPinAppWidgetSupported) return false
            return mgr.requestPinAppWidget(ComponentName(ctx, if (compact) CompactWidgetProvider::class.java else WidgetProvider::class.java), null, null)
        }
        fun refreshAll(ctx: Context) {
            val mgr = AppWidgetManager.getInstance(ctx)
            providers.forEach { provider ->
                val ids = mgr.getAppWidgetIds(ComponentName(ctx, provider))
                ids.forEach { mgr.updateAppWidget(it, render(ctx, it)) }
                @Suppress("DEPRECATION")
                mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
            }
        }
        private fun render(ctx: Context, id: Int): RemoteViews {
            val mgr = AppWidgetManager.getInstance(ctx)
            val compact = mgr.getAppWidgetInfo(id)?.provider?.className == CompactWidgetProvider::class.java.name
            val v = RemoteViews(ctx.packageName, if (compact) R.layout.compact_widget else R.layout.assistant_widget)
            val tasks = WidgetTasks.read(ctx)
            v.setTextViewText(R.id.widget_count, tasks?.let { if (it.isEmpty()) "All clear" else "${it.size} remaining" } ?: "Open Corenyth to set up")
            val add = PendingIntent.getActivity(ctx, 1, Intent(ctx, WidgetAddActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            v.setOnClickPendingIntent(R.id.widget_add, add)
            if (compact) {
                v.removeAllViews(R.id.widget_mascot)
                for (frame in 0 until 12) {
                    val child = RemoteViews(ctx.packageName, R.layout.widget_mascot_frame)
                    child.setImageViewBitmap(R.id.mascot_frame, WidgetMascot.frame(frame))
                    v.addView(R.id.widget_mascot, child)
                }
            } else {
                val service = Intent(ctx, WidgetTaskService::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    .setData(Uri.parse("corenyth://widget/$id"))
                @Suppress("DEPRECATION")
                v.setRemoteAdapter(R.id.widget_list, service)
                v.setEmptyView(R.id.widget_list, R.id.widget_empty)
                v.setTextViewText(R.id.widget_empty, if (tasks == null) "Open Corenyth once to get started." else "You're all caught up.\nAdd something with +")
                val done = Intent(ctx, WidgetProvider::class.java).setAction(COMPLETE)
                    .setData(Uri.parse("corenyth://widget/$id/done"))
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                v.setPendingIntentTemplate(R.id.widget_list, PendingIntent.getBroadcast(ctx, id, done, flags))
            }
            return v
        }
    }
}
class CompactWidgetProvider : WidgetProvider()
