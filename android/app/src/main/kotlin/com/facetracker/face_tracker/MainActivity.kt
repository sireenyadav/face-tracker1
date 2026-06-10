package com.facetracker.face_tracker

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.facetracker/control"
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
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
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
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
}
