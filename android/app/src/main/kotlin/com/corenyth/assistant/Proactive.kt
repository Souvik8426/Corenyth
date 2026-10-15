package com.corenyth.assistant

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

/**
 * Proactive delivery with the app closed. Exact AlarmManager alarms fire [ProactiveReceiver];
 * the job runs in Dart (lib/services/proactive.dart: re-read the task, write the main-chat
 * message once per occurrence, notify, advance a daily reminder, re-arm the review). It goes to
 * a live app engine when there is one, else to a single headless engine running `proactiveMain`
 * (lib/main.dart). Database transactions and occurrence keys protect overlapping delivery. No model runs here.
 * If Dart fails or takes too long, a still-current event-time reminder shows its saved title.
 *
 * Job argument lists (Dart AppServices.runProactive): ["alert", reminderId, triggerMs],
 * ["review", triggerMs], ["reconcile"], ["done"|"snooze", taskId, reminderId, triggerMs].
 */
object Proactive {
    const val CHANNEL = "assistant/alarms"
    const val REVIEW_ID = 1_999_999_999 // lib/services/proactive.dart reviewNotificationId
    const val EXTRA_TARGET = "corenyth_target"
    const val ACTION_ALARM = "com.corenyth.assistant.PROACTIVE_ALARM"
    const val ACTION_DONE = "com.corenyth.assistant.PROACTIVE_DONE"
    const val ACTION_SNOOZE = "com.corenyth.assistant.PROACTIVE_SNOOZE"
    private const val NOTIFY_CHANNEL = "reminders" // same channel as before: user settings carry over
    private const val TIMEOUT_MS = 9_000L

    /** Channels of live app engines (MainActivity and its voice subclass), newest last. */
    val appChannels = ArrayList<MethodChannel>()

    /** Notification target the app was opened with, taken once by Dart ("takeLaunch"). */
    var launchTarget: String? = null

    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var headless: MethodChannel? = null
    private var headlessReady = false
    private val waiting = ArrayList<() -> Unit>()
    private var active = 0

    /** Runs one job (main thread); [done] is called exactly once. */
    fun run(ctx: Context, args: List<Any>, done: () -> Unit) {
        val app = ctx.applicationContext
        var finished = false
        val finish = { ok: Boolean ->
            if (!finished) {
                finished = true
                if (!ok) {
                    try { fallback(app, args) } catch (_: Exception) { /* delivery is best effort */ }
                }
                WidgetProvider.refreshAll(app)
                app.sendBroadcast(Intent(app, ProactiveRefreshReceiver::class.java))
                active--
                done()
            }
        }
        active++
        main.postDelayed({ finish(false) }, TIMEOUT_MS)
        val result = object : MethodChannel.Result {
            override fun success(r: Any?) = finish(true)
            override fun error(code: String, msg: String?, details: Any?) = finish(false)
            override fun notImplemented() = finish(false)
        }
        try {
            val live = appChannels.lastOrNull()
            if (live != null) {
                live.invokeMethod("proactive", args, result)
                return
            }
            val ch = headless ?: start(app)
            if (headlessReady) ch.invokeMethod("proactive", args, result)
            else waiting.add { if (!finished) ch.invokeMethod("proactive", args, result) }
        } catch (_: Exception) {
            finish(false)
        }
    }

    private fun start(ctx: Context): MethodChannel {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(ctx)
        loader.ensureInitializationComplete(ctx, null)
        val e = FlutterEngine(ctx) // registers the plugins (sqflite) automatically
        val ch = channel(ctx, e.dartExecutor.binaryMessenger)
        engine = e
        headless = ch
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "proactiveMain"))
        return ch
    }

    // Keep this process's single delivery engine/connection for later jobs.
    // Destroying an isolate does not close sqflite's process-static connections;
    // Android reclaims the idle process and its connections together instead.

    /** Methods Dart calls on [CHANNEL]; the app engines and the headless one register it. */
    fun channel(ctx: Context, messenger: BinaryMessenger): MethodChannel {
        val app = ctx.applicationContext
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "arm" -> {
                        arm(app, call.argument<Number>("id")!!.toInt(),
                            call.argument<Number>("at")!!.toLong(), true)
                        result.success(null)
                    }
                    "armReview" -> {
                        arm(app, REVIEW_ID, call.argument<Number>("at")!!.toLong(), false)
                        result.success(null)
                    }
                    "disarm" -> {
                        disarm(app, call.argument<Number>("id")!!.toInt())
                        result.success(null)
                    }
                    "notify" -> {
                        notify(app, call.arguments as Map<*, *>)
                        result.success(null)
                    }
                    "takeLaunch" -> {
                        result.success(launchTarget)
                        launchTarget = null
                    }
                    "ready" -> {
                        headlessReady = true
                        val jobs = ArrayList(waiting)
                        waiting.clear()
                        jobs.forEach { it() }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("exact_alarms_not_permitted", e.message, null)
            } catch (e: Exception) {
                result.error("proactive_failed", e.message, null)
            }
        }
        return ch
    }

    private fun alarmIntent(ctx: Context, id: Int, at: Long?): PendingIntent {
        val i = Intent(ctx, ProactiveReceiver::class.java).setAction(ACTION_ALARM)
            .setData(Uri.parse("corenyth://alarm/$id"))
        if (at != null) i.putExtra("at", at)
        return PendingIntent.getBroadcast(ctx, id, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Same id = replaces the previous alarm. Throws when [exactOnly] and exact alarms are denied. */
    private fun arm(ctx: Context, id: Int, at: Long, exactOnly: Boolean) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = alarmIntent(ctx, id, at)
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
        if (!exact && exactOnly) throw SecurityException("exact alarms are not allowed")
        when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M -> am.setExact(AlarmManager.RTC_WAKEUP, at, pi)
            exact -> am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            else -> am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    /** Cancels the alarm and removes its notification if still shown. */
    private fun disarm(ctx: Context, id: Int) {
        (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(alarmIntent(ctx, id, null))
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(id)
    }

    /** Map keys: id, title, body, target, taskId?, reminderId?, at?, actions ("done"/"snooze"). */
    @Suppress("DEPRECATION") // pre-O builder/priority and int-icon actions: minSdk is below 26
    private fun notify(ctx: Context, n: Map<*, *>) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(NOTIFY_CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(NOTIFY_CHANNEL, "Reminders", NotificationManager.IMPORTANCE_HIGH))
            }
            Notification.Builder(ctx, NOTIFY_CHANNEL)
        } else {
            Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
        }
        val id = (n["id"] as Number).toInt()
        val body = n["body"] as String
        val open = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_TARGET, n["target"] as String)
        b.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(n["title"] as String)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(PendingIntent.getActivity(ctx, id, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        val task = (n["taskId"] as Number?)?.toInt()
        val reminder = (n["reminderId"] as Number?)?.toInt()
        if (task != null && reminder != null) {
            for (a in (n["actions"] as List<*>?).orEmpty()) {
                val i = Intent(ctx, ProactiveReceiver::class.java)
                    .setAction(if (a == "done") ACTION_DONE else ACTION_SNOOZE)
                    .setData(Uri.parse("corenyth://$a/$id"))
                    .putExtra("notification", id).putExtra("task", task)
                    .putExtra("reminder", reminder)
                    .putExtra("at", (n["at"] as Number?)?.toLong() ?: 0L)
                b.addAction(0, if (a == "done") "Done" else "Snooze 10 min",
                    PendingIntent.getBroadcast(ctx, id, i,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
        }
        nm.notify(id, b.build())
    }

    /**
     * Dart failed or timed out: an alert that is an enabled event-time reminder, still at this
     * trigger, for a pending (or no) task, and not delivered yet shows its saved title. Same
     * schema and occurrence key as Dart (alertKey: "alert:<id>:<triggerMs>"). The chat message is
     * filed by the app's catch-up later. Optional nudges/follow-ups are not shown this way.
     */
    private fun fallback(ctx: Context, args: List<Any>) {
        if (args.firstOrNull() == "review") {
            val f = ctx.getDatabasePath("assistant.db")
            if (!f.exists()) return
            SQLiteDatabase.openDatabase(f.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery("SELECT follow_up, quiet_start FROM assistant_preferences LIMIT 1", null).use { c ->
                    if (!c.moveToFirst() || c.getInt(0) == 0) return
                    val minute = ((if (c.isNull(1)) 1320 else c.getInt(1)) + 1410) % 1440
                    val next = Calendar.getInstance().apply {
                        set(Calendar.HOUR_OF_DAY, minute / 60)
                        set(Calendar.MINUTE, minute % 60)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                        if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
                    }
                    arm(ctx, REVIEW_ID, next.timeInMillis, false)
                }
            }
            return
        }
        if (args.firstOrNull() != "alert") return
        val id = (args[1] as Number).toInt()
        val at = (args[2] as Number).toLong()
        val f = ctx.getDatabasePath("assistant.db")
        if (!f.exists()) return
        val row = try {
            SQLiteDatabase.openDatabase(f.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery(
                    "SELECT r.title, r.task_id FROM reminders r LEFT JOIN tasks t ON t.id = r.task_id " +
                        "WHERE r.id = ? AND r.enabled = 1 AND r.trigger_at = ? AND r.kind = 'reminder' " +
                        "AND (r.task_id IS NULL OR t.status = 'pending') " +
                        "AND NOT EXISTS (SELECT 1 FROM proactive_events WHERE key = ?)",
                    arrayOf(id.toString(), at.toString(), "alert:$id:$at")
                ).use { c ->
                    if (c.moveToFirst()) c.getString(0) to (if (c.isNull(1)) null else c.getInt(1)) else null
                }
            }
        } catch (e: Exception) {
            null
        } ?: return
        notify(ctx, mapOf("id" to id, "title" to "Reminder", "body" to row.first,
            "target" to (row.second?.let { "task:$it" } ?: "chat:main")))
    }
}

/** Alarms, Done/Snooze actions, and boot / app update / time or zone change (re-arm + catch-up). */
class ProactiveReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val args: List<Any> = when (intent.action) {
            Proactive.ACTION_ALARM -> {
                val id = intent.data?.lastPathSegment?.toIntOrNull() ?: return
                val at = intent.getLongExtra("at", 0L)
                if (id == Proactive.REVIEW_ID) listOf("review", at) else listOf("alert", id, at)
            }
            Proactive.ACTION_DONE, Proactive.ACTION_SNOOZE -> {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(intent.getIntExtra("notification", 0))
                listOf(if (intent.action == Proactive.ACTION_DONE) "done" else "snooze",
                    intent.getIntExtra("task", 0), intent.getIntExtra("reminder", 0),
                    intent.getLongExtra("at", 0L))
            }
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_TIME_CHANGED -> listOf("reconcile")
            else -> return
        }
        val pending = goAsync()
        Proactive.run(ctx, args) { pending.finish() }
    }
}

/** Refresh an open UI after the separate delivery process changes local data. */
class ProactiveRefreshReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        Proactive.appChannels.forEach { it.invokeMethod("proactive", listOf("refresh")) }
    }
}
