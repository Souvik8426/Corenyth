package com.corenyth.assistant

import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import java.text.DateFormat
import java.util.Date

data class WidgetTask(val id: Long, val title: String, val due: Long?)
object WidgetTasks {
    fun read(ctx: Context): List<WidgetTask>? = try {
        SQLiteDatabase.openDatabase(ctx.getDatabasePath("assistant.db").path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            db.rawQuery("SELECT id,title,due_at FROM tasks WHERE status='pending' ORDER BY due_at IS NULL,due_at,priority DESC,id", null).use { c ->
                buildList { while (c.moveToNext()) add(WidgetTask(c.getLong(0), c.getString(1), if (c.isNull(2)) null else c.getLong(2))) }
            }
        }
    } catch (_: Exception) { null }
}
class WidgetTaskService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Factory(applicationContext)
    private class Factory(val ctx: Context) : RemoteViewsFactory {
        private var tasks = emptyList<WidgetTask>()
        override fun onCreate() {}
        override fun onDataSetChanged() { tasks = WidgetTasks.read(ctx).orEmpty() }
        override fun onDestroy() { tasks = emptyList() }
        override fun getCount() = tasks.size
        override fun getViewAt(position: Int): RemoteViews? {
            val task = tasks.getOrNull(position) ?: return null
            return RemoteViews(ctx.packageName, R.layout.widget_task_row).apply {
                setTextViewText(R.id.task_title, task.title)
                setTextViewText(R.id.task_due, task.due?.let { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it)) } ?: "")
                setViewVisibility(R.id.task_due, if (task.due == null) android.view.View.GONE else android.view.View.VISIBLE)
                setContentDescription(R.id.task_done, "Complete ${task.title}")
                setOnClickFillInIntent(R.id.task_done, Intent().putExtra("task", task.id))
            }
        }
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewTypeCount() = 1
        override fun getItemId(position: Int) = tasks.getOrNull(position)?.id ?: -1L
        override fun hasStableIds() = true
    }
}
