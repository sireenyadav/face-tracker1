package com.facetracker.face_tracker

import android.annotation.SuppressLint
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import org.json.JSONObject
import kotlin.collections.ArrayDeque
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.pow

class FaceAnalyzer(private val onFocusScoreUpdated: (Int, String, String) -> Unit) : ImageAnalysis.Analyzer {

    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .setMinFaceSize(0.35f)
            .build()
    )

    // Gaussian Decay Constants
    private val sigmaYaw = 15.0
    private val sigmaPitch = 20.0
    
    // EMA Constants
    private val alphaEyes = 0.2
    private val alphaScore = 0.3
    
    // State variables
    private var emaLeftEyeOpen = 1.0
    private var emaRightEyeOpen = 1.0
    private var smoothedScore = 100.0

    // Rolling Window Queue for Contextual Pose Classification Engine
    private val pitchHistory = ArrayDeque<Float>()
    private val yawHistory = ArrayDeque<Float>()
    private var lastEvaluationTimeMs = 0L
    private var currentState = "SCREEN_FOCUSED"

    private var lastInferenceTimeMs = 0L

    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(imageProxy: ImageProxy) {
        val currentTime = System.currentTimeMillis()
        if (currentTime - lastInferenceTimeMs < 500) {
            imageProxy.close()
            return
        }
        lastInferenceTimeMs = currentTime

        val mediaImage = imageProxy.image
        if (mediaImage != null) {
            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
            detector.process(image)
                .addOnSuccessListener { faces ->
                    var currentFrameScore = 100.0
                    val outputJson = JSONObject()
                    
                    if (faces.isEmpty()) {
                        smoothedScore = (alphaScore * 0.0) + ((1.0 - alphaScore) * smoothedScore)
                        val predictedState = "No Face Detected"
                        
                        outputJson.put("focus_score", smoothedScore.toInt())
                        outputJson.put("predicted_state", predictedState)
                        onFocusScoreUpdated(smoothedScore.toInt(), predictedState, outputJson.toString())
                        return@addOnSuccessListener
                    }
                    
                    val face = faces.first()
                    val yaw = face.headEulerAngleY.toDouble()
                    val pitch = face.headEulerAngleX.toDouble()
                    
                    // 1. Throttle state evaluation to 1 FPS
                    val currentTime = System.currentTimeMillis()
                    if (currentTime - lastEvaluationTimeMs >= 1000) {
                        if (pitchHistory.size >= 5) pitchHistory.removeFirst()
                        if (yawHistory.size >= 5) yawHistory.removeFirst()
                        
                        pitchHistory.addLast(pitch.toFloat())
                        yawHistory.addLast(yaw.toFloat())
                        
                        currentState = classifyHeadState(pitch.toFloat(), yaw.toFloat())
                        lastEvaluationTimeMs = currentTime
                    }
                    
                    // 2. Gaussian Posture Decay
                    val weightYaw = exp(-(yaw.pow(2)) / (2 * sigmaYaw.pow(2)))
                    // Bypass pitch penalty if explicitly WRITING
                    val weightPitch = if (currentState == "WRITING") {
                        1.0 
                    } else {
                        exp(-(pitch.pow(2)) / (2 * sigmaPitch.pow(2)))
                    }
                    
                    // 3. Eye Openness EMA
                    val rawLeftEye = (face.leftEyeOpenProbability ?: 1.0f).toDouble()
                    val rawRightEye = (face.rightEyeOpenProbability ?: 1.0f).toDouble()
                    
                    emaLeftEyeOpen = (alphaEyes * rawLeftEye) + ((1.0 - alphaEyes) * emaLeftEyeOpen)
                    emaRightEyeOpen = (alphaEyes * rawRightEye) + ((1.0 - alphaEyes) * emaRightEyeOpen)
                    
                    val eyeOpenEMA = (emaLeftEyeOpen + emaRightEyeOpen) / 2.0
                    
                    // 4. Dynamic Multiplier Integration
                    val stateMultiplier = when (currentState) {
                        "SCREEN_FOCUSED" -> 1.0
                        "WRITING" -> 0.85
                        "NEUTRAL_DRIFT" -> 0.65
                        "PHONE_CHECK_SUSPECT" -> 0.30
                        "DISTRACTED" -> 0.15
                        else -> 0.65
                    }
                    
                    // 5. The Upgraded Master Equation
                    currentFrameScore = 100.0 * weightYaw * weightPitch * eyeOpenEMA * stateMultiplier
                    
                    // Final EMA Smoothing
                    smoothedScore = (alphaScore * currentFrameScore) + ((1.0 - alphaScore) * smoothedScore)

                    // Build output JSON object
                    outputJson.put("focus_score", smoothedScore.toInt())
                    outputJson.put("predicted_state", currentState)
                    outputJson.put("w_yaw", weightYaw)
                    outputJson.put("w_pitch", weightPitch)
                    outputJson.put("w_eyes", eyeOpenEMA)
                    outputJson.put("state_multiplier", stateMultiplier)

                    onFocusScoreUpdated(smoothedScore.toInt(), currentState, outputJson.toString())
                }
                .addOnCompleteListener {
                    imageProxy.close()
                }
        } else {
            imageProxy.close()
        }
    }

    private fun classifyHeadState(currentPitch: Float, currentYaw: Float): String {
        val pitchSize = pitchHistory.size
        
        val absPitch = abs(currentPitch)
        val absYaw = abs(currentYaw)
        
        // DISTRACTED: |Yaw| > 35 sustained continuously for 3 or more seconds
        val distracted = yawHistory.size >= 3 && yawHistory.takeLast(3).all { abs(it) > 35f }
        if (distracted) {
            return "DISTRACTED"
        }
        
        // PHONE_CHECK_SUSPECT: Instantaneous pitch downward velocity spikes sharply
        var instantaneousPitchVelocity = 0f
        if (pitchSize >= 2) {
            val last = pitchHistory.last()
            val prev = pitchHistory.elementAt(pitchSize - 2)
            instantaneousPitchVelocity = last - prev
        }
        if (instantaneousPitchVelocity < -8.0f) {
            return "PHONE_CHECK_SUSPECT"
        }
        
        // SCREEN_FOCUSED: |Pitch| <= 20 and |Yaw| <= 25
        if (absPitch <= 20f && absYaw <= 25f) {
            return "SCREEN_FOCUSED"
        }
        
        // WRITING: Pitch < -25, |Yaw| <= 20, rolling pitch variance < 2.0
        var rollingPitchVariance = 0f
        if (pitchSize >= 2) {
            var sumDiffs = 0f
            for (i in 1 until pitchSize) {
                sumDiffs += abs(pitchHistory.elementAt(i) - pitchHistory.elementAt(i - 1))
            }
            rollingPitchVariance = sumDiffs / (pitchSize - 1)
        }
        if (currentPitch < -25f && absYaw <= 20f && rollingPitchVariance < 2.0f) {
            return "WRITING"
        }
        
        return "NEUTRAL_DRIFT"
    }
}
