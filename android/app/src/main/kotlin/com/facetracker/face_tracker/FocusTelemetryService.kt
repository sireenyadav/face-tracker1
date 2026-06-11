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
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.Response
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

    private var cameraProvider: ProcessCameraProvider? = null
    private var webSocket: WebSocket? = null

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
        const val ACTION_PAUSE_CAMERA = "PAUSE_CAMERA"
        const val ACTION_RESUME_CAMERA = "RESUME_CAMERA"
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
        if (intent?.action == ACTION_PAUSE_CAMERA) {
            cameraProvider?.unbindAll()
            return START_STICKY
        }
        if (intent?.action == ACTION_RESUME_CAMERA) {
            startCameraAnalysis()
            return START_STICKY
        }

        intent?.let {
            sessionId = it.getStringExtra("sessionId") ?: "11111111-1111-1111-1111-111111111111"
            subjectTag = it.getStringExtra("subjectTag") ?: ""
            targetExam = it.getStringExtra("targetExam") ?: ""
            activityType = it.getStringExtra("activityType") ?: ""
            chapterName = it.getStringExtra("chapterName") ?: ""
            lectureNumber = it.getIntExtra("lectureNumber", 0)
        }

        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
        val startedAt = sdf.format(Date())
        dbHelper.startSession(sessionId, subjectTag, targetExam, activityType, chapterName, lectureNumber, startedAt)

        serviceStartTime = System.currentTimeMillis()
        startForegroundServiceNotification()
        startCameraAnalysis()
        
        startSyncEngineLoop()
        startRealtimeWebSocket()

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
                
                val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
                sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
                val timestamp = sdf.format(Date())
                
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
                delay(60_000L) // 60-second batched data push loop
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
                        putExtra("isLive", true)
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

    private fun startRealtimeWebSocket() {
        val wsUrl = SUPABASE_URL.replace("https://", "wss://") + "/realtime/v1/websocket?apikey=$SUPABASE_ANON_KEY&vsn=1.0.0"
        
        val request = Request.Builder()
            .url(wsUrl)
            .build()

        webSocket = httpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                val joinPayload = JSONObject().apply {
                    put("topic", "realtime:public:webrtc_signaling")
                    put("event", "phx_join")
                    put("payload", JSONObject())
                    put("ref", "1")
                }.toString()
                webSocket.send(joinPayload)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val json = JSONObject(text)
                    val payload = json.optJSONObject("payload") ?: return
                    val record = payload.optJSONObject("record")
                    
                    val isVideoRequest = (record?.optBoolean("video_request", false) == true) ||
                                         (payload.optBoolean("video_request", false) == true) ||
                                         (record?.optString("type") == "offer_parent")
                                         
                    if (isVideoRequest) {
                        handleVideoRequest()
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                reconnectWebSocket()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                reconnectWebSocket()
            }
        })
    }

    private fun reconnectWebSocket() {
        if (!serviceJob.isCancelled) {
            serviceScope.launch {
                delay(5000L) // Wait 5 seconds before reconnecting
                startRealtimeWebSocket()
            }
        }
    }

    private fun handleVideoRequest() {
        stopCameraAnalysis()
        
        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("START_VIDEO_COUNTDOWN", true)
        }
        
        if (intent != null) {
            startActivity(intent)
        }
    }

    private fun stopCameraAnalysis() {
        cameraProvider?.unbindAll()
    }

    private fun handleSessionStop() {
        stopCameraAnalysis()
        webSocket?.close(1000, "Service stopped")
        
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
        val endedAt = sdf.format(Date())
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
        webSocket?.close(1000, "Service destroyed")
        serviceJob.cancel()
        dbHelper.close()
    }
}
