package com.facetracker.face_tracker

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import kotlinx.coroutines.*
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlin.math.pow
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.facetracker/control"
    private val EVENT_CHANNEL = "com.facetracker/telemetryStream"
    private val SYNC_CHANNEL = "com.facetracker/syncStream"
    private val BROADCAST_CHANNEL = "com.facetracker/broadcastReceiver"

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var syncEventChannel: EventChannel? = null
    private var broadcastMessageChannel: BasicMessageChannel<Any?>? = null

    private var eventSink: EventChannel.EventSink? = null
    private var syncEventSink: EventChannel.EventSink? = null

    private val PERMISSIONS_REQUEST_CODE = 1001
    private var pendingStartServiceIntent: Intent? = null
    private var pendingMethodChannelResult: MethodChannel.Result? = null
    private var pendingRoute: String? = null

    // Calibration state
    private var calibrationResult: MethodChannel.Result? = null
    private var calibrationJob: Job? = null
    private val calibScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var calibCameraProvider: ProcessCameraProvider? = null

    // NECK_STRAIN BroadcastReceiver → forwards to Flutter via BasicMessageChannel
    private val neckStrainReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == "com.facetracker.NECK_STRAIN") {
                runOnUiThread {
                    broadcastMessageChannel?.send("NECK_STRAIN")
                }
            }
        }
    }

    private val telemetryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == FocusTelemetryService.ACTION_TELEMETRY_UPDATE) {
                val score = intent.getIntExtra(FocusTelemetryService.EXTRA_SCORE, 100)
                val state = intent.getStringExtra(FocusTelemetryService.EXTRA_STATE) ?: "Unknown"
                val updateMap = mapOf("score" to score, "state" to state)
                eventSink?.success(updateMap)
            }
        }
    }

    private val syncReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == FocusTelemetryService.ACTION_SYNC_UPDATE) {
                val syncedRecords = intent.getIntExtra("syncedRecords", 0)
                val isLive = intent.getBooleanExtra("isLive", false)
                val updateMap = mapOf("syncedRecords" to syncedRecords, "isLive" to isLive)
                syncEventSink?.success(updateMap)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.getStringExtra("EXTRA_ROUTE")?.let {
            pendingRoute = it
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("EXTRA_ROUTE")?.let {
            methodChannel?.invokeMethod("route", it)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        
        broadcastMessageChannel = BasicMessageChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BROADCAST_CHANNEL,
            StandardMessageCodec.INSTANCE
        )

        val neckStrainFilter = IntentFilter("com.facetracker.NECK_STRAIN")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(neckStrainReceiver, neckStrainFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(neckStrainReceiver, neckStrainFilter)
        }

        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                val filter = IntentFilter(FocusTelemetryService.ACTION_TELEMETRY_UPDATE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(telemetryReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    registerReceiver(telemetryReceiver, filter)
                }
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                try { unregisterReceiver(telemetryReceiver) } catch (e: Exception) { /* ignore */ }
            }
        })

        syncEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, SYNC_CHANNEL)
        syncEventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                syncEventSink = events
                val filter = IntentFilter(FocusTelemetryService.ACTION_SYNC_UPDATE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(syncReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    registerReceiver(syncReceiver, filter)
                }
            }

            override fun onCancel(arguments: Any?) {
                syncEventSink = null
                try { unregisterReceiver(syncReceiver) } catch (e: Exception) { /* ignore */ }
            }
        })

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialRoute" -> {
                    result.success(pendingRoute)
                    pendingRoute = null
                }
                "startService" -> {
                    val configJson = call.argument<String>("config")
                    if (configJson != null) {
                        try {
                            val json = JSONObject(configJson)
                            val intent = Intent(this, FocusTelemetryService::class.java).apply {
                                putExtra("sessionId", json.optString("sessionId"))
                                putExtra("subjectTag", json.optString("subjectTag"))
                                putExtra("targetExam", json.optString("targetExam"))
                                putExtra("activityType", json.optString("activityType"))
                                putExtra("chapterName", json.optString("chapterName"))
                                putExtra("lectureNumber", json.optInt("lectureNumber", 0))
                                // Pass calibration values from config JSON
                                putExtra("baselineYaw", json.optDouble("baselineYaw", 0.0).toFloat())
                                putExtra("baselinePitch", json.optDouble("baselinePitch", 0.0).toFloat())
                                putExtra("sigmaYaw", json.optDouble("sigmaYaw", 15.0))
                                putExtra("sigmaPitch", json.optDouble("sigmaPitch", 20.0))
                            }

                            val permissionsNeeded = mutableListOf<String>()
                            if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                                permissionsNeeded.add(Manifest.permission.CAMERA)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                    permissionsNeeded.add(Manifest.permission.POST_NOTIFICATIONS)
                                }
                            }

                            if (permissionsNeeded.isNotEmpty()) {
                                pendingStartServiceIntent = intent
                                pendingMethodChannelResult = result
                                ActivityCompat.requestPermissions(this, permissionsNeeded.toTypedArray(), PERMISSIONS_REQUEST_CODE)
                            } else {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startForegroundService(intent)
                                } else {
                                    startService(intent)
                                }
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.error("JSON_ERROR", "Failed to parse config json", null)
                        }
                    } else {
                        result.error("INVALID_ARGS", "Config JSON missing", null)
                    }
                }
                "stopService" -> {
                    val intent = Intent(this, FocusTelemetryService::class.java).apply {
                        action = FocusTelemetryService.ACTION_STOP_SERVICE
                    }
                    startService(intent)
                    result.success(true)
                }
                "pauseCamera" -> {
                    val intent = Intent(this@MainActivity, FocusTelemetryService::class.java).apply {
                        action = FocusTelemetryService.ACTION_PAUSE_CAMERA
                    }
                    var handled = false
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            if (intent?.action == "com.facetracker.CAMERA_RELEASED" && !handled) {
                                handled = true
                                result.success(true)
                                try { unregisterReceiver(this) } catch (e: Exception) {}
                            }
                        }
                    }
                    val filter = IntentFilter("com.facetracker.CAMERA_RELEASED")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(receiver, filter)
                    }
                    startService(intent)
                    
                    CoroutineScope(Dispatchers.Main).launch {
                        delay(2000)
                        if (!handled) {
                            handled = true
                            try { unregisterReceiver(receiver) } catch (e: Exception) {}
                            result.error("CAMERA_RELEASED_TIMEOUT", "Camera release timed out", null)
                        }
                    }
                }
                "resumeCamera" -> {
                    val intent = Intent(this@MainActivity, FocusTelemetryService::class.java).apply {
                        action = FocusTelemetryService.ACTION_RESUME_CAMERA
                    }
                    var handled = false
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            if (intent?.action == "com.facetracker.CAMERA_RESUMED" && !handled) {
                                handled = true
                                result.success(true)
                                try { unregisterReceiver(this) } catch (e: Exception) {}
                            }
                        }
                    }
                    val filter = IntentFilter("com.facetracker.CAMERA_RESUMED")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(receiver, filter)
                    }
                    startService(intent)

                    CoroutineScope(Dispatchers.Main).launch {
                        delay(2000)
                        if (!handled) {
                            handled = true
                            try { unregisterReceiver(receiver) } catch (e: Exception) {}
                            result.error("CAMERA_RESUMED_TIMEOUT", "Camera resume timed out", null)
                        }
                    }
                }
                "runCalibration" -> {
                    // 30-second baseline calibration: collects yaw/pitch readings and computes mean + std dev
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                        result.error("PERMISSION_DENIED", "Camera permission required for calibration", null)
                        return@setMethodCallHandler
                    }
                    calibrationResult = result
                    startCalibration()
                }
                else -> result.notImplemented()
            }
        }
    }

    @SuppressLint("UnsafeOptInUsageError")
    private fun startCalibration() {
        val yawReadings = mutableListOf<Float>()
        val pitchReadings = mutableListOf<Float>()
        val calibDurationMs = 30_000L
        val startTime = System.currentTimeMillis()

        val faceDetector = FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setMinFaceSize(0.25f)
                .build()
        )

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            calibCameraProvider = cameraProviderFuture.get()

            val analyzer = ImageAnalysis.Builder()
                .setTargetResolution(Size(640, 480))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()

            analyzer.setAnalyzer(Executors.newSingleThreadExecutor()) { imageProxy ->
                val elapsed = System.currentTimeMillis() - startTime
                if (elapsed >= calibDurationMs) {
                    imageProxy.close()
                    finishCalibration(yawReadings, pitchReadings, faceDetector)
                    return@setAnalyzer
                }

                val mediaImage = imageProxy.image
                if (mediaImage != null) {
                    val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
                    faceDetector.process(image)
                        .addOnSuccessListener { faces ->
                            if (faces.isNotEmpty()) {
                                val face = faces.first()
                                yawReadings.add(face.headEulerAngleY)
                                pitchReadings.add(face.headEulerAngleX)
                            }
                        }
                        .addOnCompleteListener { imageProxy.close() }
                } else {
                    imageProxy.close()
                }
            }

            try {
                calibCameraProvider?.unbindAll()
                calibCameraProvider?.bindToLifecycle(this, CameraSelector.DEFAULT_FRONT_CAMERA, analyzer)
            } catch (e: Exception) {
                calibrationResult?.error("CAMERA_ERROR", "Calibration camera failed: ${e.message}", null)
                calibrationResult = null
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun finishCalibration(
        yawReadings: List<Float>,
        pitchReadings: List<Float>,
        faceDetector: com.google.mlkit.vision.face.FaceDetector
    ) {
        calibCameraProvider?.unbindAll()
        faceDetector.close()

        val result = calibrationResult ?: return
        calibrationResult = null

        if (yawReadings.isEmpty()) {
            // No face detected — return safe defaults
            runOnUiThread {
                result.success(mapOf(
                    "baselineYaw" to 0.0,
                    "baselinePitch" to 0.0,
                    "sigmaYaw" to 15.0,
                    "sigmaPitch" to 20.0,
                    "sampleCount" to 0
                ))
            }
            return
        }

        val meanYaw = yawReadings.average().toFloat()
        val meanPitch = pitchReadings.average().toFloat()

        // Compute standard deviation; clamp to sensible range
        val stdYaw = yawReadings.map { (it - meanYaw).pow(2) }.average()
            .let { sqrt(it).toFloat() }
            .coerceIn(8f, 25f)
        val stdPitch = pitchReadings.map { (it - meanPitch).pow(2) }.average()
            .let { sqrt(it).toFloat() }
            .coerceIn(10f, 30f)

        runOnUiThread {
            result.success(mapOf(
                "baselineYaw" to meanYaw.toDouble(),
                "baselinePitch" to meanPitch.toDouble(),
                "sigmaYaw" to stdYaw.toDouble(),
                "sigmaPitch" to stdPitch.toDouble(),
                "sampleCount" to yawReadings.size
            ))
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSIONS_REQUEST_CODE) {
            val cameraIndex = permissions.indexOf(Manifest.permission.CAMERA)
            val cameraGranted = cameraIndex == -1 || (cameraIndex >= 0 && grantResults[cameraIndex] == PackageManager.PERMISSION_GRANTED)

            if (cameraGranted) {
                pendingStartServiceIntent?.let {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(it)
                    } else {
                        startService(it)
                    }
                    pendingMethodChannelResult?.success(true)
                }
            } else {
                pendingMethodChannelResult?.error("PERMISSION_DENIED", "Camera permission is required", null)
            }
            pendingStartServiceIntent = null
            pendingMethodChannelResult = null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        calibScope.cancel()
        calibCameraProvider?.unbindAll()
        try { unregisterReceiver(neckStrainReceiver) } catch (e: Exception) { /* ignore */ }
    }
}
