package com.facetracker.face_tracker

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.facetracker/control"
    private val EVENT_CHANNEL = "com.facetracker/telemetryStream"
    
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    
    private val PERMISSIONS_REQUEST_CODE = 1001
    private var pendingStartServiceIntent: Intent? = null
    private var pendingMethodChannelResult: MethodChannel.Result? = null

    private val telemetryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == FocusTelemetryService.ACTION_TELEMETRY_UPDATE) {
                val score = intent.getIntExtra(FocusTelemetryService.EXTRA_SCORE, 100)
                val state = intent.getStringExtra(FocusTelemetryService.EXTRA_STATE) ?: "Unknown"
                
                val updateMap = mapOf(
                    "score" to score,
                    "state" to state
                )
                eventSink?.success(updateMap)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        
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
                try {
                    unregisterReceiver(telemetryReceiver)
                } catch (e: Exception) {
                    // receiver might not be registered
                }
            }
        })
        
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val configJson = call.argument<String>("config")
                    if (configJson != null) {
                        try {
                            val json = JSONObject(configJson)
                            val intent = Intent(this, FocusTelemetryService::class.java).apply {
                                putExtra("subjectTag", json.optString("subjectTag"))
                                putExtra("targetExam", json.optString("targetExam"))
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
                else -> result.notImplemented()
            }
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
}
