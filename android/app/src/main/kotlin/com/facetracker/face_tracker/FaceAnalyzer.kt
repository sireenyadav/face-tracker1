package com.facetracker.face_tracker

import android.annotation.SuppressLint
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.pow

// ─────────────────────────────────────────────────────────────────────────────
// FaceAnalyzer
//
// Implements a deep multi-signal focus scoring engine for JEE lecture monitoring.
// Key paradigm: reading from a book or writing notes should DROP the focus score
// because the student should be watching the lecture on screen, not doing offline
// work.
//
// Constructor receives calibration data collected during a 30-second baseline
// calibration phase so that individual head-pose resting positions do not bias
// the scoring unfairly.
// ─────────────────────────────────────────────────────────────────────────────
class FaceAnalyzer(
    private val onFocusScoreUpdated: (Int, String, String) -> Unit,
    private val baselineYaw: Float = 0f,     // resting yaw from calibration
    private val baselinePitch: Float = 0f,   // resting pitch from calibration
    private val sigmaYaw: Double = 15.0,     // std-dev of yaw during calibration
    private val sigmaPitch: Double = 20.0    // std-dev of pitch during calibration
) : ImageAnalysis.Analyzer {

    // ── ML Kit detector ──────────────────────────────────────────────────────
    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_NONE)
            .setMinFaceSize(0.25f)
            .build()
    )

    // ── Inference throttle ────────────────────────────────────────────────────
    // Process at most one frame every 500 ms → ~2 FPS for ML Kit
    private var lastInferenceTimeMs = 0L

    // ── Blink tracking ────────────────────────────────────────────────────────
    private var consecutiveClosedFrames = 0
    private var eyeFactor = 1.0

    // Temporal Attention Engine
    // History (timestamped for thermal throttling immunity)
    private val pitchHistory = java.util.concurrent.ConcurrentLinkedDeque<Pair<Long, Float>>()
    private val yawHistory   = java.util.concurrent.ConcurrentLinkedDeque<Pair<Long, Float>>()
    private var lastHistoryPushMs = 0L

    // Thermal Throttling Hook
    @Volatile
    var isThermalThrottling = false

    // Reading Offline Tracker
    private var readingOfflineConsecutiveMs = 0L
    private var lastStateTimeMs = 0L

    // Exponential weights — most recent = 1.0, each step back * 0.85
    private val decayFactor = 0.85

    // Weighted statistics (updated each time history is evaluated)
    private var weightedMeanPitch    = 0.0
    private var weightedMeanYaw      = 0.0
    private var weightedVarPitch     = 0.0
    private var weightedVarYaw       = 0.0
    private var motionStability      = 1.0

    // ── State classification ──────────────────────────────────────────────────
    private var currentState = "SCREEN_FOCUSED"

    // Consecutive-second counters for DISTRACTED and NECK_STRAIN_ALERT
    private var distractedConsecutiveSeconds  = 0
    private var neckStrainConsecutiveSeconds  = 0

    // ── Final score ───────────────────────────────────────────────────────────
    private var smoothedScore = 100.0
    private val alphaScore    = 0.25

    // ── Analyze ───────────────────────────────────────────────────────────────
    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(imageProxy: ImageProxy) {
        val nowMs = System.currentTimeMillis()

        // Track how long we've been in READING_OFFLINE
        if (lastStateTimeMs != 0L && currentState == "READING_OFFLINE") {
            readingOfflineConsecutiveMs += (nowMs - lastStateTimeMs)
        } else if (currentState != "READING_OFFLINE") {
            readingOfflineConsecutiveMs = 0L
        }
        lastStateTimeMs = nowMs

        // Dynamic Inference Gate: 3000ms if throttling or stable offline for > 5 mins
        val isStableOffline = readingOfflineConsecutiveMs > 5 * 60 * 1000L
        val inferenceIntervalMs = if (isThermalThrottling || isStableOffline) 3000L else 500L

        if (nowMs - lastInferenceTimeMs < inferenceIntervalMs) {
            imageProxy.close()
            return
        }
        lastInferenceTimeMs = nowMs

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        detector.process(image)
            .addOnSuccessListener { faces ->
                val frameMs = System.currentTimeMillis()

                // ── No face detected ──────────────────────────────────────────
                if (faces.isEmpty()) {
                    smoothedScore = alphaScore * 0.0 + (1.0 - alphaScore) * smoothedScore
                    val state = "NO_FACE_DETECTED"
                    val json = JSONObject().apply {
                        put("focus_score", smoothedScore.toInt())
                        put("predicted_state", state)
                    }
                    onFocusScoreUpdated(smoothedScore.toInt(), state, json.toString())
                    return@addOnSuccessListener
                }

                val face = faces.first()

                // Raw Euler angles (degrees)
                val rawYaw   = face.headEulerAngleY   // positive = right
                val rawPitch = face.headEulerAngleX   // negative = down

                // Calibrated deltas — centre each student's personal resting pose
                val calibratedYaw   = rawYaw   - baselineYaw
                val calibratedPitch = rawPitch - baselinePitch

                // Detection confidence based on tracking ID availability
                val detectionConfidence = if (face.trackingId != null) 1.0 else 0.75

                // ── Blink Tracking (Microsleeps only) ─────────────────────────
                val leftEyeProb  = (face.leftEyeOpenProbability  ?: 1.0f).toDouble()
                val rightEyeProb = (face.rightEyeOpenProbability ?: 1.0f).toDouble()
                val eyeProb      = (leftEyeProb + rightEyeProb) / 2.0

                if (eyeProb < 0.4) {
                    consecutiveClosedFrames++
                } else {
                    consecutiveClosedFrames = 0
                }

                // If eyes closed for 2+ consecutive frames (>= 1000ms), heavy penalty
                eyeFactor = if (consecutiveClosedFrames >= 2) 0.30 else 1.0

                // ── Temporal history push (1 Hz) ──────────────────────────────
                if (frameMs - lastHistoryPushMs >= 1000L) {
                    pitchHistory.addLast(Pair(frameMs, calibratedPitch))
                    yawHistory.addLast(Pair(frameMs, calibratedYaw))
                    lastHistoryPushMs = frameMs

                    // Recompute weighted statistics
                    recomputeWeightedStats()
                }

                // ── State classification ──────────────────────────────────────
                currentState = classifyState(calibratedYaw, calibratedPitch, frameMs)

                val stateMultiplier = stateToMultiplier(currentState)

                // ── Gaussian decay on calibrated pose ─────────────────────────
                val gaussianYaw   = exp(-(calibratedYaw.pow(2))   / (2.0 * sigmaYaw.pow(2)))
                val gaussianPitch = exp(-(calibratedPitch.pow(2)) / (2.0 * sigmaPitch.pow(2)))

                // ── Motion stability blend ─────────────────────────────────────
                // Erratic head movement slightly lowers the score
                val stabilityBlend = 0.7 + 0.3 * motionStability

                // ── Master score equation ─────────────────────────────────────
                val rawScore = 100.0 *
                    gaussianYaw *
                    gaussianPitch *
                    eyeFactor *
                    stateMultiplier *
                    detectionConfidence *
                    stabilityBlend

                smoothedScore = alphaScore * rawScore + (1.0 - alphaScore) * smoothedScore
                smoothedScore = smoothedScore.coerceIn(0.0, 100.0)

                // ── Blink rate removed due to Nyquist sampling limits ─────────
                val blinkRatePerMin = 0

                // ── Emit telemetry ────────────────────────────────────────────
                val json = JSONObject().apply {
                    put("focus_score",          smoothedScore.toInt())
                    put("predicted_state",      currentState)
                    put("w_yaw",                gaussianYaw.round4())
                    put("w_pitch",              gaussianPitch.round4())
                    put("w_eyes",               eyeFactor.round4())
                    put("state_multiplier",     stateMultiplier.round4())
                    put("detection_confidence", detectionConfidence.round4())
                    put("motion_stability",     motionStability.round4())
                    put("blink_state",          blinkState.name)
                    put("blink_rate_per_min",   blinkRatePerMin)
                    put("calibrated_yaw",       calibratedYaw.toDouble().round4())
                    put("calibrated_pitch",     calibratedPitch.toDouble().round4())
                }

                onFocusScoreUpdated(smoothedScore.toInt(), currentState, json.toString())
            }
            .addOnCompleteListener {
                imageProxy.close()
            }
    }

    // FSM removed to avoid Nyquist-Shannon violation at 2 FPS

    // ── Temporal Attention Engine ─────────────────────────────────────────────
    /**
     * Recomputes exponentially-weighted mean and variance for both pitch and yaw.
     *
     * Weight array: most recent entry (index size-1) = 1.0, each step back ×0.85.
     * Variance = E[x²] − (E[x])²  using the same weights.
     */
    private fun recomputeWeightedStats() {
        val nowMs = System.currentTimeMillis()
        
        // Eviction window: 10s normally, 60s when throttled (to maintain N=20 points)
        val isStableOffline = readingOfflineConsecutiveMs > 5 * 60 * 1000L
        val evictionWindowMs = if (isThermalThrottling || isStableOffline) 60000L else 10000L

        // Evict stale history
        while (pitchHistory.peekFirst()?.first?.let { nowMs - it > evictionWindowMs } == true) {
            pitchHistory.removeFirst()
        }
        while (yawHistory.peekFirst()?.first?.let { nowMs - it > evictionWindowMs } == true) {
            yawHistory.removeFirst()
        }

        weightedMeanPitch  = computeWeightedMean(pitchHistory)
        weightedMeanYaw    = computeWeightedMean(yawHistory)
        weightedVarPitch   = computeWeightedVariance(pitchHistory, weightedMeanPitch)
        weightedVarYaw     = computeWeightedVariance(yawHistory,   weightedMeanYaw)

        // motion stability: 0–1, high variance → lower stability
        motionStability = 1.0 / (1.0 + weightedVarPitch / 10.0 + weightedVarYaw / 10.0)
    }

    private fun computeWeightedMean(history: java.util.concurrent.ConcurrentLinkedDeque<Pair<Long, Float>>): Double {
        if (history.isEmpty()) return 0.0
        var weightSum   = 0.0
        var weightedSum = 0.0
        val size = history.size
        var i = 0
        for (item in history) {
            // The last element (most recent) has index size-1 → power 0 → weight 1.0
            val age    = (size - 1 - i)
            val weight = decayFactor.pow(age)
            weightedSum += weight * item.second
            weightSum   += weight
            i++
        }
        return if (weightSum > 0.0) weightedSum / weightSum else 0.0
    }

    private fun computeWeightedVariance(history: java.util.concurrent.ConcurrentLinkedDeque<Pair<Long, Float>>, mean: Double): Double {
        if (history.size < 2) return 0.0
        var weightSum    = 0.0
        var weightedSumSq = 0.0
        val size = history.size
        var i = 0
        for (item in history) {
            val age    = (size - 1 - i)
            val weight = decayFactor.pow(age)
            val diff   = item.second - mean
            weightedSumSq += weight * diff * diff
            weightSum     += weight
            i++
        }
        return if (weightSum > 0.0) weightedSumSq / weightSum else 0.0
    }

    // ── State classification FSM ──────────────────────────────────────────────
    /**
     * Priority order (highest first):
     *   DISTRACTED > PHONE_CHECK_SUSPECT > DROWSY > SCREEN_FOCUSED >
     *   NECK_STRAIN_ALERT > READING_OFFLINE > WRITING_OFFLINE > NEUTRAL_DRIFT
     */
    private fun classifyState(
        calibratedYaw:   Float,
        calibratedPitch: Float,
        nowMs:           Long
    ): String {
        val absYaw   = abs(calibratedYaw)
        val absPitch = abs(calibratedPitch)

        // ── 1. DISTRACTED ─────────────────────────────────────────────────────
        // |calibratedYaw| > 35 sustained for 3+ consecutive history entries
        // (each entry ~1 s → 3+ seconds of continuous distraction)
        val distracted = yawHistory.size >= 3 &&
            yawHistory.toList().takeLast(3).all { abs(it.second) > 35f }

        if (distracted) {
            distractedConsecutiveSeconds++
        } else {
            distractedConsecutiveSeconds = 0
        }

        if (distractedConsecutiveSeconds >= 3) {
            return "DISTRACTED"
        }

        // ── 2. PHONE_CHECK_SUSPECT ────────────────────────────────────────────
        // Pitch moves more than 15° downward in any 800 ms window.
        // Check the last 2 pitch history entries (≈ 2 × 500 ms = 1 s interval
        // since history is pushed at 1 Hz, so 2 entries = 2 s apart; we also
        // check the instantaneous delta from this frame vs the most recent stored
        // entry which was captured at most 500 ms ago).
        if (pitchHistory.size >= 2) {
            val historyList = pitchHistory.toList()
            val latestStored = historyList.last().second
            val prevStored   = historyList[historyList.size - 2].second
            // Downward pitch = increasingly negative calibratedPitch
            val storedDelta  = latestStored - prevStored      // stored 1 s apart
            val liveToStored = calibratedPitch - latestStored // this frame minus last stored

            // Phone check: pitch drops > 15° rapidly (< 800 ms window approximated
            // by the live-to-stored delta within one inference interval ≤ 500 ms)
            if (liveToStored < -15f || storedDelta < -15f) {
                return "PHONE_CHECK_SUSPECT"
            }
        }

        // ── 3. DROWSY ─────────────────────────────────────────────────────────
        val isDrowsy    = (consecutiveClosedFrames >= 2)
        val highBlink   = false // Deprecated due to Nyquist sampling limits

        if (isDrowsy || highBlink) {
            return "DROWSY"
        }

        // ── 4. SCREEN_FOCUSED ─────────────────────────────────────────────────
        // Eye openness check: eyeFactor must be reasonably high (> 0.5)
        if (absYaw <= 18f && absPitch <= 15f && eyeFactor > 0.5) {
            neckStrainConsecutiveSeconds = 0
            return "SCREEN_FOCUSED"
        }

        // ── 5. NECK_STRAIN_ALERT ──────────────────────────────────────────────
        // calibratedPitch < -35 for 5+ consecutive seconds
        if (calibratedPitch < -35f) {
            neckStrainConsecutiveSeconds++
        } else {
            neckStrainConsecutiveSeconds = 0
        }

        if (neckStrainConsecutiveSeconds >= 5) {
            return "NECK_STRAIN_ALERT"
        }

        // ── 6. READING_OFFLINE ────────────────────────────────────────────────
        // Stable downward gaze at book angle: pitch between -20° and -40°,
        // |yaw| ≤ 20°, pitch weighted variance < 3.0 (very stable = not moving)
        if (calibratedPitch in -40f..-20f &&
            absYaw <= 20f &&
            weightedVarPitch < 3.0
        ) {
            return "READING_OFFLINE"
        }

        // ── 7. WRITING_OFFLINE ────────────────────────────────────────────────
        // Moderate downward gaze with head movement (writing involves small
        // oscillations): pitch < -25°, pitch variance 3–8
        if (calibratedPitch < -25f &&
            weightedVarPitch in 3.0..8.0
        ) {
            return "WRITING_OFFLINE"
        }

        // ── 8. NEUTRAL_DRIFT ─────────────────────────────────────────────────
        return "NEUTRAL_DRIFT"
    }

    /** Maps a state string to its focus multiplier. */
    private fun stateToMultiplier(state: String): Double = when (state) {
        "SCREEN_FOCUSED"     -> 1.00
        "DISTRACTED"         -> 0.10
        "PHONE_CHECK_SUSPECT"-> 0.20
        "DROWSY"             -> 0.35
        "NECK_STRAIN_ALERT"  -> 0.50
        "READING_OFFLINE"    -> 0.45
        "WRITING_OFFLINE"    -> 0.40
        else                 -> 0.60   // NEUTRAL_DRIFT
    }

    // ── Utility ───────────────────────────────────────────────────────────────
    private fun Double.round4(): Double =
        (this * 10_000.0).toLong() / 10_000.0

    private fun Float.pow(n: Int): Double = this.toDouble().pow(n)
    private fun Double.pow(n: Int): Double = Math.pow(this, n.toDouble())
}
