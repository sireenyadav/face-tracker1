package com.facetracker.face_tracker

import android.annotation.SuppressLint
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions

class FaceAnalyzer(private val onFocusScoreUpdated: (Int, String) -> Unit) : ImageAnalysis.Analyzer {

    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .setMinFaceSize(0.35f)
            .build()
    )

    private var consecutiveMicroSleepFrames = 0
    private var lastScore = 100

    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage != null) {
            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
            detector.process(image)
                .addOnSuccessListener { faces ->
                    var score = 100
                    var state = "Locked In"
                    
                    if (faces.isEmpty()) {
                        score = 0
                        state = "No Face Detected"
                    } else {
                        val face = faces.first()
                        val yaw = face.headEulerAngleY
                        val pitch = face.headEulerAngleX
                        
                        if (kotlin.math.abs(yaw) > 20 || kotlin.math.abs(pitch) > 20) {
                            score -= 30
                            state = "Distracted (Looking away)"
                        }

                        val leftEyeOpen = face.leftEyeOpenProbability ?: 1.0f
                        val rightEyeOpen = face.rightEyeOpenProbability ?: 1.0f

                        if (leftEyeOpen < 0.15f && rightEyeOpen < 0.15f) {
                            consecutiveMicroSleepFrames++
                            if (consecutiveMicroSleepFrames >= 3) {
                                score = 10
                                state = "Micro-sleep Detected"
                            }
                        } else {
                            consecutiveMicroSleepFrames = 0
                        }
                    }
                    
                    if (score >= 75 && state.startsWith("Distracted").not() && state.startsWith("No Face").not() && state.startsWith("Micro").not()) {
                        state = "Locked In"
                    }
                    
                    lastScore = score
                    onFocusScoreUpdated(score, state)
                }
                .addOnCompleteListener {
                    imageProxy.close()
                }
        } else {
            imageProxy.close()
        }
    }
}
