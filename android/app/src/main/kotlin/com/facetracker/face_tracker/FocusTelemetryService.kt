package com.facetracker.face_tracker

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

class FocusTelemetryService : LifecycleService() {

    private var subjectTag: String = ""
    private var targetExam: String = ""

    private var currentFocusScore = 100
    private var currentState = "Locked In"

    private var cameraProvider: ProcessCameraProvider? = null
    private lateinit var dbHelper: FocusDatabaseHelper

    companion object {
        const val ACTION_STOP_SERVICE = "STOP_TELEMETRY_SESSION"
    }

    override fun onCreate() {
        super.onCreate()
        dbHelper = FocusDatabaseHelper(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        
        if (intent?.action == ACTION_STOP_SERVICE) {
            handleSessionStop()
            return START_NOT_STICKY
        }

        intent?.let {
            subjectTag = it.getStringExtra("subjectTag") ?: ""
            targetExam = it.getStringExtra("targetExam") ?: ""
        }

        startForegroundServiceNotification()
        startCameraAnalysis()

        return START_STICKY
    }

    private fun startForegroundServiceNotification() {
        val channelId = "FocusTelemetryChannel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Focus Telemetry",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }

        updateNotification()
    }

    private fun updateNotification() {
        val contentText = if (currentFocusScore >= 75) {
            "[Locked In] Focusing on $subjectTag | Score: $currentFocusScore"
        } else {
            "⚠️ DISTRACTED! Return to your studies."
        }

        val notification = NotificationCompat.Builder(this, "FocusTelemetryChannel")
            .setContentTitle("Focus Tracker Active")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setUsesChronometer(true)
            .setOnlyAlertOnce(true)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(1, notification)
        
        // ensure foreground maintains state
        startForeground(1, notification)
    }

    private fun startCameraAnalysis() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()
            val analyzer = ImageAnalysis.Builder()
                .setTargetResolution(Size(640, 480))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()

            analyzer.setAnalyzer(Executors.newSingleThreadExecutor(), FaceAnalyzer { score, state ->
                currentFocusScore = score
                currentState = state
                
                // 1 Hz execution is roughly maintained by image analysis speed if fast enough, 
                // but we will do UI and DB logic here on each evaluated frame.
                val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).format(Date())
                val activeApp = "com.facetracker.face_tracker" // Mocked, as full UsageStats is out of scope for this offline refactor snippet
                
                dbHelper.insertRecord(timestamp, score, state, activeApp, subjectTag)
                
                // Update notification dynamically
                updateNotification()
            })

            val cameraSelector = CameraSelector.DEFAULT_FRONT_CAMERA

            try {
                cameraProvider?.unbindAll()
                cameraProvider?.bindToLifecycle(this, cameraSelector, analyzer)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun stopCameraAnalysis() {
        cameraProvider?.unbindAll()
    }

    private fun handleSessionStop() {
        stopCameraAnalysis()
        
        // Export DB to JSON
        exportDatabaseToJson()
        
        // Purge table
        dbHelper.clearTable()
        
        stopForeground(true)
        stopSelf()
    }

    private fun exportDatabaseToJson() {
        val records = dbHelper.getAllRecords()
        val jsonArray = JSONArray()
        for (record in records) {
            val jsonObj = JSONObject(record)
            jsonArray.put(jsonObj)
        }

        val jsonString = jsonArray.toString(4) // human-readable formatting

        val documentsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
        val faceTrackerDir = File(documentsDir, "FaceTracker/session_logs")
        if (!faceTrackerDir.exists()) {
            faceTrackerDir.mkdirs()
        }

        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val file = File(faceTrackerDir, "session_$timestamp.json")
        try {
            file.writeText(jsonString)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCameraAnalysis()
    }
}
