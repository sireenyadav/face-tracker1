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

// ─────────────────────────────────────────────────────────────────────────────
// FocusTelemetryService
//
// Foreground service that drives the JEE focus-tracking pipeline:
//   • CameraX → FaceAnalyzer → local SQLite (TelemetryDbHelper)
//   • 30-second batched Supabase REST sync
//   • Phoenix-protocol WebSocket with 45-second heartbeat pings
//   • Exponential backoff reconnection
//   • NECK_STRAIN_ALERT local broadcast
//
// Calibration parameters (baselineYaw, baselinePitch, sigmaYaw, sigmaPitch)
// are read from the starting Intent and forwarded to FaceAnalyzer.
// ─────────────────────────────────────────────────────────────────────────────
class FocusTelemetryService : LifecycleService() {

    // ── Supabase credentials ──────────────────────────────────────────────────
    private val SUPABASE_URL      = "https://crmjzxhlggfpisknbjrr.supabase.co"
    private val SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" +
        ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNybWp6eGhsZ2dmcGlza25ianJyIiwi" +
        "cm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTE3MjMxOCwiZXhwIjoyMDk2" +
        "NzQ4MzE4fQ.8CoDj9TVVuScYfTEvrF8kc99E5JpNOXGF-NJVj6SvQ8"

    // ── Persistence ───────────────────────────────────────────────────────────
    private lateinit var dbHelper: TelemetryDbHelper

    // ── Session metadata ──────────────────────────────────────────────────────
    private var sessionId    : String = ""
    private var subjectTag   : String = ""
    private var targetExam   : String = ""
    private var activityType : String = ""
    private var chapterName  : String = ""
    private var lectureNumber: Int    = 0

    // ── Calibration data ──────────────────────────────────────────────────────
    private var baselineYaw  : Float  = 0f
    private var baselinePitch: Float  = 0f
    private var sigmaYaw     : Double = 15.0
    private var sigmaPitch   : Double = 20.0

    // ── Live focus state ──────────────────────────────────────────────────────
    private var currentFocusScore = 100
    private var currentState      = "Initializing..."
    private var serviceStartTime  = 0L

    // ── Camera ────────────────────────────────────────────────────────────────
    private var cameraProvider: ProcessCameraProvider? = null

    // ── WebSocket ─────────────────────────────────────────────────────────────
    private var webSocket         : WebSocket? = null
    private var reconnectAttempts : Int        = 0

    // Heartbeat coroutine handle — cancelled when the socket closes / service stops
    private var heartbeatJob: Job? = null

    // ── Coroutine scope ───────────────────────────────────────────────────────
    private val serviceJob   = SupervisorJob()
    private val serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)

    // ── HTTP client ───────────────────────────────────────────────────────────
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .pingInterval(0, TimeUnit.SECONDS)  // manual pings via heartbeat coroutine
        .build()

    // ── Constants ─────────────────────────────────────────────────────────────
    companion object {
        const val ACTION_STOP_SERVICE    = "STOP_TELEMETRY_SESSION"
        const val ACTION_PAUSE_CAMERA    = "PAUSE_CAMERA"
        const val ACTION_RESUME_CAMERA   = "RESUME_CAMERA"
        const val ACTION_TELEMETRY_UPDATE = "com.facetracker.TELEMETRY_UPDATE"
        const val ACTION_SYNC_UPDATE     = "com.facetracker.SYNC_UPDATE"
        const val EXTRA_SCORE            = "focusScore"
        const val EXTRA_STATE            = "focusState"

        private const val NOTIFICATION_ID       = 1
        private const val CHANNEL_ID            = "FocusTelemetryChannel"
        private const val SYNC_INTERVAL_MS      = 30_000L   // 30 s batched push
        private const val HEARTBEAT_INTERVAL_MS = 45_000L   // 45 s WebSocket ping
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        dbHelper = TelemetryDbHelper(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)

        // ── Handle control actions ────────────────────────────────────────────
        when (intent?.action) {
            ACTION_STOP_SERVICE -> {
                handleSessionStop()
                return START_NOT_STICKY
            }
            ACTION_PAUSE_CAMERA -> {
                cameraProvider?.unbindAll()
                return START_STICKY
            }
            ACTION_RESUME_CAMERA -> {
                startCameraAnalysis()
                return START_STICKY
            }
        }

        // ── Read session metadata from intent ─────────────────────────────────
        intent?.let {
            sessionId     = it.getStringExtra("sessionId")     ?: "11111111-1111-1111-1111-111111111111"
            subjectTag    = it.getStringExtra("subjectTag")    ?: ""
            targetExam    = it.getStringExtra("targetExam")    ?: ""
            activityType  = it.getStringExtra("activityType")  ?: ""
            chapterName   = it.getStringExtra("chapterName")   ?: ""
            lectureNumber = it.getIntExtra("lectureNumber",    0)

            // ── Calibration data ─────────────────────────────────────────────
            baselineYaw   = it.getFloatExtra("baselineYaw",   0f)
            baselinePitch = it.getFloatExtra("baselinePitch", 0f)
            sigmaYaw      = it.getDoubleExtra("sigmaYaw",     15.0)
            sigmaPitch    = it.getDoubleExtra("sigmaPitch",   20.0)
        }

        // ── Persist session start ─────────────────────────────────────────────
        val sdf = utcSdf()
        val startedAt = sdf.format(Date())
        dbHelper.startSession(
            sessionId, subjectTag, targetExam, activityType,
            chapterName, lectureNumber, startedAt
        )

        serviceStartTime = System.currentTimeMillis()
        startForegroundServiceNotification()
        startCameraAnalysis()
        startSyncEngineLoop()
        startRealtimeWebSocket()

        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        heartbeatJob?.cancel()
        webSocket?.close(1000, "Service destroyed")
        serviceJob.cancel()
        dbHelper.close()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Foreground notification
    // ─────────────────────────────────────────────────────────────────────────

    private fun startForegroundServiceNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
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
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Focus Fusion Engine Active")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setUsesChronometer(true)
            .setWhen(serviceStartTime)
            .setOnlyAlertOnce(true)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, notification)
        startForeground(NOTIFICATION_ID, notification)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Camera / FaceAnalyzer
    // ─────────────────────────────────────────────────────────────────────────

    private fun startCameraAnalysis() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()

            val imageAnalysis = ImageAnalysis.Builder()
                .setTargetResolution(Size(720, 540))      // upgraded from 640×480
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()

            // Pass calibration data to the upgraded FaceAnalyzer
            val faceAnalyzer = FaceAnalyzer(
                onFocusScoreUpdated = { score, state, jsonStr ->
                    handleFocusUpdate(score, state, jsonStr)
                },
                baselineYaw   = baselineYaw,
                baselinePitch = baselinePitch,
                sigmaYaw      = sigmaYaw,
                sigmaPitch    = sigmaPitch
            )

            imageAnalysis.setAnalyzer(
                Executors.newSingleThreadExecutor(),
                faceAnalyzer
            )

            val cameraSelector = CameraSelector.DEFAULT_FRONT_CAMERA

            try {
                cameraProvider?.unbindAll()
                cameraProvider?.bindToLifecycle(this, cameraSelector, imageAnalysis)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Focus update handler (called by FaceAnalyzer callback)
    // ─────────────────────────────────────────────────────────────────────────

    private fun handleFocusUpdate(score: Int, state: String, jsonStr: String) {
        currentFocusScore = score
        currentState      = state

        val timestamp = utcSdf().format(Date())

        // ── Persist locally (zero-lag) ────────────────────────────────────────
        try {
            val obj   = JSONObject(jsonStr)
            val yaw   = obj.optDouble("w_yaw",   1.0)
            val pitch = obj.optDouble("w_pitch",  1.0)
            val eyes  = obj.optDouble("w_eyes",   1.0)

            dbHelper.insertTelemetry(
                sessionId, timestamp, score, state,
                "com.facetracker.face_tracker", yaw, pitch, eyes
            )
        } catch (e: Exception) {
            e.printStackTrace()
        }

        // ── Broadcast to Flutter/Activity UI ──────────────────────────────────
        val broadcastIntent = Intent(ACTION_TELEMETRY_UPDATE).apply {
            putExtra(EXTRA_SCORE, score)
            putExtra(EXTRA_STATE, state)
            setPackage(packageName)
        }
        sendBroadcast(broadcastIntent)

        // ── Neck strain special broadcast ─────────────────────────────────────
        if (state == "NECK_STRAIN_ALERT") {
            val strainIntent = Intent("com.facetracker.NECK_STRAIN").apply {
                setPackage(packageName)
            }
            sendBroadcast(strainIntent)
        }

        updateNotification()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sync engine — 30 s batched push to Supabase REST
    // ─────────────────────────────────────────────────────────────────────────

    private fun startSyncEngineLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(SYNC_INTERVAL_MS)
                syncLocalDatabase()
            }
        }
    }

    private suspend fun syncLocalDatabase() {
        // ── 1. Sync unsynced telemetry rows ───────────────────────────────────
        val (batchArray, recordIds) = dbHelper.getUnsyncedTelemetry()
        if (batchArray.length() > 0) {
            try {
                val jsonPayload = JSONObject().apply {
                    put("p_telemetry_data", batchArray)
                }.toString()

                val mediaType   = "application/json; charset=utf-8".toMediaType()
                val requestBody = jsonPayload.toRequestBody(mediaType)

                val request = Request.Builder()
                    .url("$SUPABASE_URL/rest/v1/rpc/bulk_insert_telemetry")
                    .post(requestBody)
                    .addHeader("apikey",        SUPABASE_ANON_KEY)
                    .addHeader("Authorization", "Bearer $SUPABASE_ANON_KEY")
                    .addHeader("Content-Type",  "application/json")
                    .build()

                val response = httpClient.newCall(request).execute()
                if (response.isSuccessful) {
                    dbHelper.markTelemetrySynced(recordIds)

                    val syncIntent = Intent(ACTION_SYNC_UPDATE).apply {
                        putExtra("syncedRecords", recordIds.size)
                        putExtra("isLive",        true)
                        setPackage(packageName)
                    }
                    sendBroadcast(syncIntent)
                }
                response.close()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        // ── 2. Sync ended session records ─────────────────────────────────────
        val endedSessions              = dbHelper.getUnsyncedSessionEnds()
        val successfullySyncedSessions = mutableListOf<String>()

        for (session in endedSessions) {
            val (id, endedAt) = session
            try {
                val jsonPayload = JSONObject().apply {
                    put("ended_at", endedAt)
                    put("status",   "completed")
                }.toString()

                val mediaType   = "application/json; charset=utf-8".toMediaType()
                val requestBody = jsonPayload.toRequestBody(mediaType)

                val request = Request.Builder()
                    .url("$SUPABASE_URL/rest/v1/focus_sessions?id=eq.$id")
                    .patch(requestBody)
                    .addHeader("apikey",        SUPABASE_ANON_KEY)
                    .addHeader("Authorization", "Bearer $SUPABASE_ANON_KEY")
                    .addHeader("Content-Type",  "application/json")
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

    // ─────────────────────────────────────────────────────────────────────────
    // Realtime WebSocket — Phoenix protocol with heartbeat + exponential backoff
    // ─────────────────────────────────────────────────────────────────────────

    private fun startRealtimeWebSocket() {
        val wsUrl = SUPABASE_URL.replace("https://", "wss://") +
            "/realtime/v1/websocket?apikey=$SUPABASE_ANON_KEY&vsn=1.0.0"

        val request = Request.Builder()
            .url(wsUrl)
            .build()

        webSocket = httpClient.newWebSocket(request, object : WebSocketListener() {

            override fun onOpen(webSocket: WebSocket, response: Response) {
                // Reset backoff counter on successful connection
                reconnectAttempts = 0

                // Join the realtime channel
                val joinPayload = JSONObject().apply {
                    put("topic",   "realtime:public:webrtc_signaling")
                    put("event",   "phx_join")
                    put("payload", JSONObject())
                    put("ref",     "1")
                }.toString()
                webSocket.send(joinPayload)

                // Start 45-second Phoenix heartbeat
                startHeartbeat(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val json    = JSONObject(text)
                    val payload = json.optJSONObject("payload") ?: return
                    val record  = payload.optJSONObject("record")

                    val isVideoRequest =
                        (record?.optBoolean("video_request", false) == true) ||
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
                heartbeatJob?.cancel()
                heartbeatJob = null
                if (code != 1000) {          // 1000 = intentional close
                    reconnectWebSocket()
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                heartbeatJob?.cancel()
                heartbeatJob = null
                reconnectWebSocket()
            }
        })
    }

    /**
     * Launches a coroutine that sends a Phoenix heartbeat ping every 45 seconds.
     * Cancelled automatically when the socket closes or the service stops.
     */
    private fun startHeartbeat(socket: WebSocket) {
        heartbeatJob?.cancel()
        heartbeatJob = serviceScope.launch {
            while (isActive) {
                delay(HEARTBEAT_INTERVAL_MS)
                try {
                    val pingJson = JSONObject().apply {
                        put("topic",   "phoenix")
                        put("event",   "heartbeat")
                        put("payload", JSONObject())
                        put("ref",     System.currentTimeMillis().toString())
                    }.toString()
                    socket.send(pingJson)
                } catch (e: Exception) {
                    e.printStackTrace()
                    break
                }
            }
        }
    }

    /**
     * Exponential backoff reconnect:
     *   attempt 0 →  5 s
     *   attempt 1 → 10 s
     *   attempt 2 → 20 s
     *   attempt 3+→ 30 s (cap)
     */
    private fun reconnectWebSocket() {
        if (serviceJob.isCancelled) return
        serviceScope.launch {
            val delayMs = minOf(5_000L * (1L shl minOf(reconnectAttempts, 3)), 30_000L)
            reconnectAttempts++
            delay(delayMs)
            startRealtimeWebSocket()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Video request handling
    // ─────────────────────────────────────────────────────────────────────────

    private fun handleVideoRequest() {
        stopCameraAnalysis()

        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            putExtra("START_VIDEO_COUNTDOWN", true)
        }

        if (intent != null) {
            startActivity(intent)
        }
    }

    private fun stopCameraAnalysis() {
        cameraProvider?.unbindAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Session stop
    // ─────────────────────────────────────────────────────────────────────────

    private fun handleSessionStop() {
        stopCameraAnalysis()
        heartbeatJob?.cancel()
        heartbeatJob = null
        webSocket?.close(1000, "Service stopped")

        val endedAt = utcSdf().format(Date())
        dbHelper.stopSession(sessionId, endedAt)

        // Final flush before tearing down
        serviceScope.launch {
            syncLocalDatabase()
            serviceJob.cancel()
            @Suppress("DEPRECATION")
            stopForeground(true)
            stopSelf()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Utility
    // ─────────────────────────────────────────────────────────────────────────

    private fun utcSdf(): SimpleDateFormat {
        return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).also {
            it.timeZone = java.util.TimeZone.getTimeZone("UTC")
        }
    }
}
