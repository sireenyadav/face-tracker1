package com.facetracker.face_tracker

import android.annotation.SuppressLint
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import org.json.JSONObject
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
    private val alphaScore = 0.2
    
    // State variables
    private var emaLeftEyeOpen = 1.0
    private var emaRightEyeOpen = 1.0
    private var smoothedScore = 100.0

    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage != null) {
            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
            detector.process(image)
                .addOnSuccessListener { faces ->
                    var currentFrameScore = 100.0
                    var predictedState = "Hyper-Focus"
                    val outputJson = JSONObject()
                    
                    if (faces.isEmpty()) {
                        smoothedScore = (alphaScore * 0.0) + ((1.0 - alphaScore) * smoothedScore)
                        predictedState = "No Face Detected"
                        
                        outputJson.put("focus_score", smoothedScore.toInt())
                        outputJson.put("predicted_state", predictedState)
                        onFocusScoreUpdated(smoothedScore.toInt(), predictedState, outputJson.toString())
                        return@addOnSuccessListener
                    }
                    
                    val face = faces.first()
                    val yaw = face.headEulerAngleY.toDouble()
                    val pitch = face.headEulerAngleX.toDouble()
                    
                    // 1. Gaussian Posture Decay
                    // W = exp(-theta^2 / (2 * sigma^2))
                    val weightYaw = exp(-(yaw.pow(2)) / (2 * sigmaYaw.pow(2)))
                    val weightPitch = exp(-(pitch.pow(2)) / (2 * sigmaPitch.pow(2)))
                    
                    // 2. Fatigue Probability (EMA)
                    val rawLeftEye = (face.leftEyeOpenProbability ?: 1.0f).toDouble()
                    val rawRightEye = (face.rightEyeOpenProbability ?: 1.0f).toDouble()
                    
                    emaLeftEyeOpen = (alphaEyes * rawLeftEye) + ((1.0 - alphaEyes) * emaLeftEyeOpen)
                    emaRightEyeOpen = (alphaEyes * rawRightEye) + ((1.0 - alphaEyes) * emaRightEyeOpen)
                    
                    val weightEyes = (emaLeftEyeOpen + emaRightEyeOpen) / 2.0
                    
                    // App Usage Penalty is 1.0 for now
                    val appUsagePenalty = 1.0
                    
                    // 3. The Master Equation
                    currentFrameScore = 100.0 * weightYaw * weightPitch * weightEyes * appUsagePenalty
                    
                    // 4. Score Smoothing
                    smoothedScore = (alphaScore * currentFrameScore) + ((1.0 - alphaScore) * smoothedScore)
                    
                    // 5. Predictive State Logic
                    val minWeight = minOf(weightYaw, weightPitch, weightEyes)
                    
                    if (smoothedScore >= 85.0) {
                        predictedState = "Hyper-Focus"
                    } else if (minWeight == weightEyes) {
                        if (weightEyes < 0.3) {
                            predictedState = "Cognitive Fatigue"
                        } else {
                            predictedState = "Drifting"
                        }
                    } else if (minWeight == weightYaw || minWeight == weightPitch) {
                        if (minWeight < 0.4) {
                            predictedState = "Digital Distraction"
                        } else {
                            predictedState = "Drifting"
                        }
                    }

                    // Build output JSON object
                    outputJson.put("focus_score", smoothedScore.toInt())
                    outputJson.put("predicted_state", predictedState)
                    outputJson.put("w_yaw", weightYaw)
                    outputJson.put("w_pitch", weightPitch)
                    outputJson.put("w_eyes", weightEyes)

                    onFocusScoreUpdated(smoothedScore.toInt(), predictedState, outputJson.toString())
                }
                .addOnCompleteListener {
                    imageProxy.close()
                }
        } else {
            imageProxy.close()
        }
    }
}
