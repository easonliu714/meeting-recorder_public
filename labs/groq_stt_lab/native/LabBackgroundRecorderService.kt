package com.example.meeting_recorder.public_lab_v37.groq_stt_lab

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Gate B only; independent from v35's onPause-to-interrupt Gate A fixture. */
class LabBackgroundRecorderService : Service() {
    companion object {
        private const val CHANNEL="lab_b_mic_v1"
        // C08: a user-configurable, high-importance reminder is separate from the microphone FGS.
        private const val REMINDER_CHANNEL="lab_c_reminder_v38"
        private const val REMINDER_ID=3702
        private const val STOP="LAB_B_USER_STOP"
        private const val START="LAB_B_EXPLICIT_START"
        private const val START_C="LAB_C_EXPLICIT_ACCELERATED_START"
        private const val C_SPEED=900L // 120 simulated minutes over 8 real seconds.
        @Volatile private var cModel:LabTwoHourReminder?=null
        @Volatile private var cRealStartMs=0L
        @Volatile private var cUiForeground=true
        @Volatile private var cDelivery="NONE"
        @Volatile private var instance:LabBackgroundRecorderService?=null
        private val active=AtomicBoolean(false)
        private val mode=AtomicInteger(0)
        private val frames=AtomicInteger(0)
        private val committed=AtomicInteger(0)
        @Volatile private var phase="idle"
        @Volatile private var code=""
        @Volatile private var resultStatus=""
        @Volatile private var resultParts=0
        @Volatile private var tailBytes=0L
        fun isActive()=active.get()
        fun setUiForeground(foreground:Boolean) { cUiForeground=foreground }
        fun begin(context:Context, acceleratedC:Boolean=false) {
            check(Build.VERSION.SDK_INT>=26){"LAB_B_ANDROID_VERSION_HOLD"}
            check(active.compareAndSet(false,true)){"LAB_B_ALREADY_RUNNING_HOLD"}
            mode.set(0);frames.set(0);committed.set(0)
            phase="starting";code="";resultStatus="";resultParts=0;tailBytes=0L
            cModel=if(acceleratedC) LabTwoHourReminder(0L) else null
            cRealStartMs=SystemClock.elapsedRealtime()
            cDelivery="NONE"
            try {
                context.startForegroundService(Intent(context,LabBackgroundRecorderService::class.java)
                    .setAction(if(acceleratedC) START_C else START))
            } catch(e:Exception) {
                active.set(false);phase="hold";code="LAB_B_SERVICE_START_HOLD"
                throw IllegalStateException(code,e)
            }
        }
        fun requestStop() { if(active.get()) mode.compareAndSet(0,2) }
        fun cContinue() {
            check(active.get() && phase=="recording") { "LAB_C_NOT_RECORDING_HOLD" }
            val m=cModel ?: error("LAB_C_NOT_ACCELERATED_HOLD")
            m.continueRecording()
            cDelivery="CONTINUED"
            instance?.dismissReminderNotification()
            instance?.showRecordingNotification()
        }
        fun cEnd() {
            check(active.get() && phase=="recording") { "LAB_C_NOT_RECORDING_HOLD" }
            val m=cModel ?: error("LAB_C_NOT_ACCELERATED_HOLD")
            m.requestEnd()
            cDelivery="END_REQUESTED"
            instance?.dismissReminderNotification()
            check(mode.compareAndSet(0,2)) { "LAB_C_ALREADY_STOPPING_HOLD" }
        }
        fun status():Map<String,Any> = mapOf("phase" to phase,"frames" to frames.get(),
            "committed" to committed.get(),"errorCode" to code,
            "lastStatus" to resultStatus,"parts" to resultParts,"tailBytes" to tailBytes,
            "cEnabled" to (cModel!=null),"cPhase" to (cModel?.state()?.name ?: "NONE"),
            "cPending" to (cModel?.pendingOnReturn() ?: false),
            "cElapsedSimMs" to (cModel?.elapsedMs() ?: 0L),
            "cDelivery" to cDelivery,"cClockMultiplier" to C_SPEED)
    }
    override fun onBind(intent:Intent?):IBinder?=null
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        instance=this
        if(intent?.action==STOP) {
            requestStop()
            return START_NOT_STICKY
        }
        if(intent?.action !in setOf(START,START_C) || !active.get()) {
            stopSelf(startId);return START_NOT_STICKY
        }
        if((intent?.action==START_C)!=(cModel!=null)) {
            phase="hold";code="LAB_C_START_MODE_HOLD";active.set(false)
            stopSelf(startId);return START_NOT_STICKY
        }
        try {
            check(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED) {
                "LAB_B_PERMISSION_HOLD"
            }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(NotificationChannel(CHANNEL,
                    "Lab 背景麥克風錄音",NotificationManager.IMPORTANCE_LOW))
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(NotificationChannel(REMINDER_CHANNEL,
                    "Lab 兩小時提醒",NotificationManager.IMPORTANCE_HIGH))
            val stop=PendingIntent.getService(this,3601,
                Intent(this,LabBackgroundRecorderService::class.java).setAction(STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val notification=Notification.Builder(this,CHANNEL)
                .setContentTitle("Groq STT Lab｜背景錄音中")
                .setContentText("錄音持續中，點選停止並封存")
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setOngoing(true)
                .addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause,
                    "停止並封存",stop).build()).build()
            if(Build.VERSION.SDK_INT>=29) {
                startForeground(3601,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else startForeground(3601,notification)
            phase="recording"
        } catch(e:Exception) {
            code=e.message?.takeIf{Regex("^LAB_[A-Z0-9_]{2,55}_HOLD$").matches(it)}
                ?:"LAB_B_FOREGROUND_HOLD"
            phase="hold";active.set(false);stopSelf(startId)
            return START_NOT_STICKY
        }
        val reminder=cModel
        if(reminder!=null) {
            Thread {
                while(active.get() && mode.get()==0 && cModel===reminder) {
                    try {
                        if(phase=="recording") {
                            val elapsed=SystemClock.elapsedRealtime()-cRealStartMs
                            check(elapsed>=0L && elapsed<=45_000L) { "LAB_C_CLOCK_RANGE_HOLD" }
                            val event=reminder.onTick(elapsed*C_SPEED,cUiForeground,true)
                            if(event!=LabTwoHourReminder.Delivery.NONE) {
                                cDelivery=event.name
                                showReminderNotification()
                            }
                        }
                        Thread.sleep(100)
                    } catch(e:Exception) {
                        code=e.message?.takeIf { it.startsWith("LAB_C_") } ?: "LAB_C_TICK_HOLD"
                        phase="hold";mode.compareAndSet(0,1)
                        break
                    }
                }
            }.start()
        }
        Thread {
            try {
                val result=LabMultiPartCapture.capture(applicationContext,mode,frames,committed)
                val status=result["status"] as? String ?:error("LAB_B_RECEIPT_HOLD")
                val parts=result["parts"] as? List<*> ?:error("LAB_B_RECEIPT_HOLD")
                val tail=result["tailBytes"] as? Long ?:error("LAB_B_RECEIPT_HOLD")
                check(status in setOf("completed","interrupted","uncommitted")){"LAB_B_RECEIPT_HOLD"}
                resultStatus=status;resultParts=parts.size;tailBytes=tail
                if(reminder!=null) {
                    if(reminder.state()==LabTwoHourReminder.Phase.STOP_REQUESTED) {
                        check(status=="completed" && parts.isNotEmpty() && tail==0L) {
                            "LAB_C_UNVERIFIED_SEAL_HOLD"
                        }
                        reminder.confirmSealed(true)
                    } else {
                        reminder.stopWithoutChoice()
                    }
                }
                phase=if(status=="completed")"completed" else "interrupted"
            } catch(e:Exception) {
                code=e.message?.takeIf{Regex("^LAB_[A-Z0-9_]{2,55}_HOLD$").matches(it)}
                    ?:"LAB_B_CAPTURE_OR_STORAGE_HOLD"
                phase="hold"
            } finally {
                active.set(false)
                dismissReminderNotification()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }.start()
        return START_NOT_STICKY
    }
    private fun showRecordingNotification() {
        val stop=PendingIntent.getService(this,3601,
            Intent(this,LabBackgroundRecorderService::class.java).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val running=Notification.Builder(this,CHANNEL)
            .setContentTitle("Groq STT Lab｜背景錄音中")
            .setContentText("提醒已確認繼續；麥克風仍在錄音")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause,
                "停止並封存",stop).build()).build()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(3601,running)
    }

    private fun dismissReminderNotification() {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(REMINDER_ID)
    }

    private fun showReminderNotification() {
        val open=PendingIntent.getActivity(this,3702,
            Intent(this,MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification=Notification.Builder(this,REMINDER_CHANNEL)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setPriority(Notification.PRIORITY_HIGH)
            .setAutoCancel(false)
            .setContentTitle("加速模擬：兩小時提醒")
            .setContentText("錄音不中斷；返回 Lab 選擇繼續或結束")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true).setContentIntent(open).build()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(REMINDER_ID,notification)
    }

    override fun onDestroy() {
        if(instance===this) instance=null
        mode.compareAndSet(0,1)
        super.onDestroy()
    }
}
