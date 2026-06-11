package com.facetracker.face_tracker

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import kotlinx.coroutines.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class FocusTelemetryService : LifecycleService() {

    private val SUPABASE_URL = "https://crmjzxhlggfpisknbjrr.supabase.co"
    private val SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNybWp6eGhsZ2dmcGlza25ianJyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTE3MjMxOCwiZXhwIjoyMDk2NzQ4MzE4fQ.8CoDj9TVVuScYfTEvrF8kc99E5JpNOXGF-NJVj6SvQ8"

    private lateinit var dbHelper: TelemetryDbHelper

    private var sessionId: String = ""
    private var subjectTag: String = ""
    private var targetExam: String = ""
    private var activityType: String = ""
    private var chapterName: String = ""
    private var lectureNumber: Int = 0

    private var currentFocusScore = 100
    private var currentState = "Initializing..."
    private var serviceStartTime: Long = 0
    private var isParentWatching = false

    private var cameraProvider: ProcessCameraProvider? = null

    // Coroutine Scopes
    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    companion object {
        const val ACTION_STOP_SERVICE = "STOP_TELEMETRY_SESSION"
        const val ACTION_TELEMETRY_UPDATE = "com.facetracker.TELEMETRY_UPDATE"
        const val ACTION_SYNC_UPDATE = "com.facetracker.SYNC_UPDATE"
        const val EXTRA_SCORE = "focusScore"
        const val EXTRA_STATE = "focusState"
    }

    override fun onCreate() {
        super.onCreate()
        dbHelper = TelemetryDbHelper(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        
        if (intent?.action == ACTION_STOP_SERVICE) {
            handleSessionStop()
            return START_NOT_STICKY
        }

        intent?.let {
            sessionId = it.getStringExtra("sessionId") ?: "11111111-1111-1111-1111-111111111111"
            subjectTag = it.getStringExtra("subjectTag") ?: ""
            targetExam = it.getStringExtra("targetExam") ?: ""
            activityType = it.getStringExtra("activityType") ?: ""
            chapterName = it.getStringExtra("chapterName") ?: ""
            lectureNumber = it.getIntExtra("lectureNumber", 0)
        }

        val startedAt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).format(Date())
        dbHelper.startSession(sessionId, subjectTag, targetExam, activityType, chapterName, lectureNumber, startedAt)

        serviceStartTime = System.currentTimeMillis()
        startForegroundServiceNotification()
        startCameraAnalysis()
        
        startSyncEngineLoop()
        startParentWatchingPollingLoop()

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
        val contentText = "State: $currentState | Score: $currentFocusScore"
        val notification = NotificationCompat.Builder(this, "FocusTelemetryChannel")
            .setContentTitle("Focus Fusion Engine Active")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setUsesChronometer(true)
            .setWhen(serviceStartTime)
            .setOnlyAlertOnce(true)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(1, notification)
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

            analyzer.setAnalyzer(Executors.newSingleThreadExecutor(), FaceAnalyzer { score, state, jsonStr ->
                currentFocusScore = score
                currentState = state
                
                val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).format(Date())
                
                // Extract metrics to save locally (0 lag)
                try {
                    val obj = JSONObject(jsonStr)
                    val yaw = obj.optDouble("w_yaw", 1.0)
                    val pitch = obj.optDouble("w_pitch", 1.0)
                    val eyes = obj.optDouble("w_eyes", 1.0)
                    
                    dbHelper.insertTelemetry(
                        sessionId, timestamp, score, state, "com.facetracker.face_tracker", yaw, pitch, eyes
                    )
                } catch (e: Exception) {
                    e.printStackTrace()
                }
                
                // Broadcast update to Activity
                val broadcastIntent = Intent(ACTION_TELEMETRY_UPDATE).apply {
                    putExtra(EXTRA_SCORE, score)
                    putExtra(EXTRA_STATE, state)
                    setPackage(packageName)
                }
                sendBroadcast(broadcastIntent)
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

    private fun startSyncEngineLoop() {
        serviceScope.launch {
            while (isActive) {
                // If parent is watching, sync every 1 second. Otherwise 5 minutes.
                val delayMs = if (isParentWatching) 1_000L else 300_000L
                delay(delayMs)
                syncLocalDatabase()
            }
        }
    }
    
    private suspend fun syncLocalDatabase() {
        // 1. Sync Telemetry
        val (batchArray, recordIds) = dbHelper.getUnsyncedTelemetry()
        if (batchArray.length() > 0) {
            try {
                val jsonPayload = JSONObject().apply {
                    put("p_telemetry_data", batchArray)
                }.toString()

                val mediaType = "application/json; charset=utf-8".toMediaType()
                val requestBody = jsonPayload.toRequestBody(mediaType)

                val request = Request.Builder()
                    .url("$SUPABASE_URL/rest/v1/rpc/bulk_insert_telemetry")
                    .post(requestBody)
                    .addHeader("apikey", SUPABASE_ANON_KEY)
                    .addHeader("Authorization", "Bearer $SUPABASE_ANON_KEY")
                    .addHeader("Content-Type", "application/json")
                    .build()

                val response = httpClient.newCall(request).execute()
                if (response.isSuccessful) {
                    dbHelper.markTelemetrySynced(recordIds)
                    
                    // Notify Flutter UI
                    val syncIntent = Intent(ACTION_SYNC_UPDATE).apply {
                        putExtra("syncedRecords", recordIds.size)
                        putExtra("isLive", isParentWatching)
                        setPackage(packageName)
                    }
                    sendBroadcast(syncIntent)
                }
                response.close()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        // 2. Sync Ended Sessions
        val endedSessions = dbHelper.getUnsyncedSessionEnds()
        val successfullySyncedSessions = mutableListOf<String>()
        
        for (session in endedSessions) {
            val (id, endedAt) = session
            try {
                val jsonPayload = JSONObject().apply {
                    put("ended_at", endedAt)
                    put("status", "completed")
                }.toString()

                val mediaType = "application/json; charset=utf-8".toMediaType()
                val requestBody = jsonPayload.toRequestBody(mediaType)

                val request = Request.Builder()
                    .url("$SUPABASE_URL/rest/v1/focus_sessions?id=eq.$id")
                    .patch(requestBody)
                    .addHeader("apikey", SUPABASE_ANON_KEY)
                    .addHeader("Authorization", "Bearer $SUPABASE_ANON_KEY")
                    .addHeader("Content-Type", "application/json")
                    .build()

                val response = httpClient.newCall(request).execute()
                if (response.isSuccessful) {
                    successfullySyncedSessions.add(id)
                }
                response.close()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        
        if (successfullySyncedSessions.isNotEmpty()) {
            dbHelper.markSessionEndSynced(successfullySyncedSessions)
        }
    }

    private fun startParentWatchingPollingLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(10_000L) // Poll every 10 seconds
                pollParentWatchingStatus()
            }
        }
    }
    
    private fun pollParentWatchingStatus() {
        try {
            val request = Request.Builder()
                .url("$SUPABASE_URL/rest/v1/device_status?device_id=eq.global&select=is_watching")
                .get()
                .addHeader("apikey", SUPABASE_ANON_KEY)
                .addHeader("Authorization", "Bearer $SUPABASE_ANON_KEY")
                .build()

            val response = httpClient.newCall(request).execute()
            if (response.isSuccessful) {
                val responseBody = response.body?.string()
                if (!responseBody.isNullOrEmpty() && responseBody != "[]") {
                    val jsonArray = org.json.JSONArray(responseBody)
                    if (jsonArray.length() > 0) {
                        isParentWatching = jsonArray.getJSONObject(0).optBoolean("is_watching", false)
                    }
                }
            }
            response.close()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopCameraAnalysis() {
        cameraProvider?.unbindAll()
    }

    private fun handleSessionStop() {
        stopCameraAnalysis()
        
        val endedAt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).format(Date())
        dbHelper.stopSession(sessionId, endedAt)
        
        // Final flush before stopping
        serviceScope.launch {
            syncLocalDatabase()
            
            serviceJob.cancel()
            stopForeground(true)
            stopSelf()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        serviceJob.cancel()
        dbHelper.close()
    }
}
