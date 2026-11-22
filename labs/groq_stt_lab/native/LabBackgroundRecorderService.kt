package com.example.meeting_recorder.public_lab_v36.groq_stt_lab

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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Gate B only; independent from v35's onPause-to-interrupt Gate A fixture. */
class LabBackgroundRecorderService : Service() {
    companion object {
        private const val CHANNEL="lab_b_mic_v1"
        private const val STOP="LAB_B_USER_STOP"
        private const val START="LAB_B_EXPLICIT_START"
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
        fun begin(context:Context) {
            check(Build.VERSION.SDK_INT>=26){"LAB_B_ANDROID_VERSION_HOLD"}
            check(active.compareAndSet(false,true)){"LAB_B_ALREADY_RUNNING_HOLD"}
            mode.set(0);frames.set(0);committed.set(0)
            phase="starting";code="";resultStatus="";resultParts=0;tailBytes=0L
            try {
                context.startForegroundService(Intent(context,LabBackgroundRecorderService::class.java).setAction(START))
            } catch(e:Exception) {
                active.set(false);phase="hold";code="LAB_B_SERVICE_START_HOLD"
                throw IllegalStateException(code,e)
            }
        }
        fun requestStop() { if(active.get()) mode.compareAndSet(0,2) }
        fun status():Map<String,Any> = mapOf("phase" to phase,"frames" to frames.get(),
            "committed" to committed.get(),"errorCode" to code,
            "lastStatus" to resultStatus,"parts" to resultParts,"tailBytes" to tailBytes)
    }
    override fun onBind(intent:Intent?):IBinder?=null
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        if(intent?.action==STOP) {
            requestStop()
            return START_NOT_STICKY
        }
        if(intent?.action!=START||!active.get()){stopSelf(startId);return START_NOT_STICKY}
        try {
            check(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED) {
                "LAB_B_PERMISSION_HOLD"
            }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(NotificationChannel(CHANNEL,
                    "Lab 背景麥克風錄音",NotificationManager.IMPORTANCE_LOW))
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
        Thread {
            try {
                val result=LabMultiPartCapture.capture(applicationContext,mode,frames,committed)
                val status=result["status"] as? String ?:error("LAB_B_RECEIPT_HOLD")
                val parts=result["parts"] as? List<*> ?:error("LAB_B_RECEIPT_HOLD")
                val tail=result["tailBytes"] as? Long ?:error("LAB_B_RECEIPT_HOLD")
                check(status in setOf("completed","interrupted","uncommitted")){"LAB_B_RECEIPT_HOLD"}
                resultStatus=status;resultParts=parts.size;tailBytes=tail
                phase=if(status=="completed")"completed" else "interrupted"
            } catch(e:Exception) {
                code=e.message?.takeIf{Regex("^LAB_[A-Z0-9_]{2,55}_HOLD$").matches(it)}
                    ?:"LAB_B_CAPTURE_OR_STORAGE_HOLD"
                phase="hold"
            } finally {
                active.set(false)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }.start()
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        mode.compareAndSet(0,1)
        super.onDestroy()
    }
}
