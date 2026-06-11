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
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class FocusTelemetryService : LifecycleService() {

    private val SUPABASE_URL = "https://crmjzxhlggfpisknbjrr.supabase.co"
    private val SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNybWp6eGhsZ2dmcGlza25ianJyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTE3MjMxOCwiZXhwIjoyMDk2NzQ4MzE4fQ.8CoDj9TVVuScYfTEvrF8kc99E5JpNOXGF-NJVj6SvQ8"

    private var subjectTag: String = ""
    private var targetExam: String = ""

    private var currentFocusScore = 100
    private var currentState = "Initializing..."
    private var serviceStartTime: Long = 0

    private var cameraProvider: ProcessCameraProvider? = null

    // Coroutine Scopes
    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)

    // Batching Array
    private val telemetryBatch = JSONArray()
    private val batchMutex = kotlinx.coroutines.sync.Mutex()

    // OkHttpClient
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    companion object {
        const val ACTION_STOP_SERVICE = "STOP_TELEMETRY_SESSION"
        const val ACTION_TELEMETRY_UPDATE = "com.facetracker.TELEMETRY_UPDATE"
        const val EXTRA_SCORE = "focusScore"
        const val EXTRA_STATE = "focusState"
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

        serviceStartTime = System.currentTimeMillis()
        startForegroundServiceNotification()
        startCameraAnalysis()
        
        startBatchUploadLoop()
        startVideoFlagPollingLoop()

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
                
                serviceScope.launch {
                    batchMutex.lock()
                    try {
                        val recordObj = JSONObject(jsonStr).apply {
                            put("timestamp", timestamp)
                            put("subject_tag", subjectTag)
                            put("target_exam", targetExam)
                        }
                        telemetryBatch.put(recordObj)
                    } finally {
                        batchMutex.unlock()
                    }
                }
                
                // Broadcast update to Activity
                val broadcastIntent = Intent(ACTION_TELEMETRY_UPDATE).apply {
                    putExtra(EXTRA_SCORE, score)
                    putExtra(EXTRA_STATE, state)
                    setPackage(packageName)
                }
                sendBroadcast(broadcastIntent)
                
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

    private fun startBatchUploadLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(60_000L) // 60-second batching
                flushTelemetryBatch()
            }
        }
    }
    
    private suspend fun flushTelemetryBatch() {
        var batchToUpload: JSONArray
        batchMutex.lock()
        try {
            if (telemetryBatch.length() == 0) return
            batchToUpload = JSONArray(telemetryBatch.toString())
            // Clear the original batch
            while (telemetryBatch.length() > 0) {
                telemetryBatch.remove(0)
            }
        } finally {
            batchMutex.unlock()
        }

        try {
            val jsonPayload = JSONObject().apply {
                put("p_telemetry_data", batchToUpload)
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
            if (!response.isSuccessful) {
                println("Failed to upload telemetry batch: ${response.code}")
            }
            response.close()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun startVideoFlagPollingLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(5_000L) // 5-second fast polling
                pollVideoRequestFlag()
            }
        }
    }
    
    private fun pollVideoRequestFlag() {
        // Placeholder for the 5-second video flag polling network request.
        // This will be expanded in Phase 4 WebRTC hookup.
    }

    private fun stopCameraAnalysis() {
        cameraProvider?.unbindAll()
    }

    private fun handleSessionStop() {
        stopCameraAnalysis()
        
        // Final flush before stopping
        serviceScope.launch {
            flushTelemetryBatch()
            
            serviceJob.cancel()
            stopForeground(true)
            stopSelf()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCameraAnalysis()
        serviceJob.cancel()
    }
}
