/**
 * FaceTrackerEdge.tsx
 *
 * Edge-AI face tracker running inside the parent's browser during a live WebRTC
 * ambush feed. Uses TensorFlow.js + MediaPipe face detector to estimate head pose
 * from keypoints, then applies a Gaussian decay scoring algorithm (ported from
 * the Android Kotlin implementation) to produce a real-time focus score.
 *
 * Key design decisions:
 *  - sigmaYaw=15°, sigmaPitch=20° (hardcoded; no calibration needed in parent browser)
 *  - 2 FPS cap (500 ms setTimeout) to avoid burning the laptop
 *  - setTimeout ID tracked in a ref → no memory leaks on cleanup
 *  - onScoreUpdate is read from a ref so the callback is never stale
 */

import React, { useEffect, useRef } from "react";
import * as tf from "@tensorflow/tfjs";
import * as faceDetection from "@tensorflow-models/face-detection";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type FocusState =
  | "SCREEN_FOCUSED"
  | "NEUTRAL_DRIFT"
  | "READING_OFFLINE"
  | "PHONE_CHECK_SUSPECT"
  | "DISTRACTED";

interface PoseEstimate {
  yawDeg: number;   // positive = turned right
  pitchDeg: number; // positive = tilted down
  eyeDistance: number; // pixels; proxy for face-camera distance
}

interface FaceTrackerEdgeProps {
  videoRef: React.RefObject<HTMLVideoElement>;
  isActive: boolean;
  onScoreUpdate: (score: number, state: string) => void;
}

// ---------------------------------------------------------------------------
// Gaussian decay helpers  (mirrors Kotlin implementation)
// ---------------------------------------------------------------------------

/** σ = 15° for yaw (left/right head turn) */
const SIGMA_YAW = 15;
/** σ = 20° for pitch (up/down tilt) */
const SIGMA_PITCH = 20;

/**
 * Gaussian score component.  Returns 1.0 when angle=0, decays toward 0
 * as the head turns away.  Formula: exp( -angle² / (2·σ²) )
 */
function gaussianDecay(angleDeg: number, sigma: number): number {
  return Math.exp(-(angleDeg * angleDeg) / (2 * sigma * sigma));
}

/**
 * Combines yaw and pitch Gaussian scores into a single 0-100 focus score.
 * Each axis is weighted equally; the product gives a 2-D decay surface.
 */
function computeGaussianScore(yawDeg: number, pitchDeg: number): number {
  const yawScore = gaussianDecay(yawDeg, SIGMA_YAW);
  const pitchScore = gaussianDecay(pitchDeg, SIGMA_PITCH);
  return Math.round(yawScore * pitchScore * 100);
}

// ---------------------------------------------------------------------------
// State classification
// ---------------------------------------------------------------------------

/**
 * Maps (yawDeg, pitchDeg, gaussianScore, faceDetected) → FocusState.
 * Mirrors the Android classifier logic.
 *
 * State boundaries (approximate):
 *   SCREEN_FOCUSED      – gScore ≥ 80; very close to center
 *   NEUTRAL_DRIFT       – gScore 60-79; slight drift, still studying
 *   READING_OFFLINE     – gScore 45-59 + high pitch-down (reading paper)
 *   PHONE_CHECK_SUSPECT – gScore 45-59 + high yaw (looking sideways)
 *   DISTRACTED          – gScore < 45 or no face
 */
function classifyState(
  yawDeg: number,
  pitchDeg: number,
  gScore: number,
  faceDetected: boolean
): FocusState {
  if (!faceDetected) return "DISTRACTED";
  if (gScore >= 80) return "SCREEN_FOCUSED";
  if (gScore >= 60) return "NEUTRAL_DRIFT";
  // Sub-60: distinguish reading offline vs phone check vs distracted
  if (gScore >= 45) {
    if (pitchDeg > 20 && Math.abs(yawDeg) < 15) return "READING_OFFLINE";
    if (Math.abs(yawDeg) > 25) return "PHONE_CHECK_SUSPECT";
    return "NEUTRAL_DRIFT";
  }
  return "DISTRACTED";
}

/**
 * Human-readable label for the state, shown in the UI.
 */
function stateLabel(state: FocusState): string {
  switch (state) {
    case "SCREEN_FOCUSED":      return "Screen Focused";
    case "NEUTRAL_DRIFT":       return "Neutral Drift";
    case "READING_OFFLINE":     return "Reading Offline";
    case "PHONE_CHECK_SUSPECT": return "Phone Check?";
    case "DISTRACTED":          return "Distracted";
  }
}

// ---------------------------------------------------------------------------
// Keypoint geometry helpers
// ---------------------------------------------------------------------------

/**
 * Estimate head pose angles from MediaPipe face keypoints.
 *
 * Coordinate conventions (image space, origin top-left):
 *   x → rightward, y → downward
 *
 * yawProxy:
 *   The nose tip shifts left/right relative to the inter-eye midpoint
 *   as the head yaws.  Normalised by eye distance to remove perspective.
 *   Multiplied by 90 to convert to approximate degrees.
 *
 * pitchProxy:
 *   The nose tip shifts downward as the head tilts down (reading), or
 *   upward as the head tilts up.
 */
function estimatePose(keypoints: faceDetection.Keypoint[]): PoseEstimate | null {
  const rightEye = keypoints.find((k) => k.name === "rightEye");
  const leftEye  = keypoints.find((k) => k.name === "leftEye");
  const noseTip  = keypoints.find((k) => k.name === "noseTip");

  if (!rightEye || !leftEye || !noseTip) return null;

  const eyeMidX = (leftEye.x + rightEye.x) / 2;
  const eyeMidY = (leftEye.y + rightEye.y) / 2;
  const eyeDistance = Math.abs(leftEye.x - rightEye.x);

  if (eyeDistance < 1) return null; // degenerate face

  // Normalised displacement, scaled to approximate degrees
  const yawProxy   = ((noseTip.x - eyeMidX) / eyeDistance) * 90;
  const pitchProxy = ((noseTip.y - eyeMidY) / eyeDistance) * 90;

  return { yawDeg: yawProxy, pitchDeg: pitchProxy, eyeDistance };
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export const FaceTrackerEdge: React.FC<FaceTrackerEdgeProps> = ({
  videoRef,
  isActive,
  onScoreUpdate,
}) => {
  const detectorRef        = useRef<faceDetection.FaceDetector | null>(null);
  const animationRef       = useRef<number>(0);
  const timeoutRef         = useRef<ReturnType<typeof setTimeout> | null>(null); // ← leak fix
  const lastScoreRef       = useRef<number>(85);
  const lastStateRef       = useRef<FocusState>("SCREEN_FOCUSED");

  // Keep a ref to onScoreUpdate so the detection loop never has a stale closure
  const onScoreUpdateRef   = useRef(onScoreUpdate);
  useEffect(() => {
    onScoreUpdateRef.current = onScoreUpdate;
  }, [onScoreUpdate]);

  // Keep a ref to isActive for the same reason
  const isActiveRef        = useRef(isActive);
  useEffect(() => {
    isActiveRef.current = isActive;
  }, [isActive]);

  // ---------------------------------------------------------------------------
  // Load TensorFlow.js + model once on mount
  // ---------------------------------------------------------------------------
  useEffect(() => {
    let mounted = true;

    const initTF = async () => {
      try {
        await tf.ready();
        const model          = faceDetection.SupportedModels.MediaPipeFaceDetector;
        const detectorConfig: faceDetection.MediaPipeFaceDetectorTfjsModelConfig = {
          runtime: "tfjs",
          maxFaces: 1,
        };
        const detector = await faceDetection.createDetector(model, detectorConfig);
        if (mounted) detectorRef.current = detector;
      } catch (e) {
        console.error("[FaceTrackerEdge] TF init error:", e);
      }
    };

    initTF();

    return () => {
      mounted = false;
      detectorRef.current?.dispose();
      detectorRef.current = null;
    };
  }, []);

  // ---------------------------------------------------------------------------
  // Detection loop — starts/stops with isActive
  // ---------------------------------------------------------------------------
  useEffect(() => {
    let loopRunning = true;

    const detectFace = async () => {
      if (!loopRunning) return;

      const video    = videoRef.current;
      const detector = detectorRef.current;

      if (!isActiveRef.current || !video || !detector || video.readyState < 2) {
        // Not ready yet – reschedule without running inference
        scheduleNext();
        return;
      }

      try {
        const faces = await detector.estimateFaces(video, { flipHorizontal: false });

        if (faces.length > 0) {
          const pose = estimatePose(faces[0].keypoints);

          if (pose) {
            const rawScore  = computeGaussianScore(pose.yawDeg, pose.pitchDeg);
            const state     = classifyState(pose.yawDeg, pose.pitchDeg, rawScore, true);
            lastStateRef.current = state;

            // Smooth the score with a 70/30 IIR filter to avoid jarring jumps
            const smoothed = Math.round(lastScoreRef.current * 0.7 + rawScore * 0.3);
            lastScoreRef.current = Math.max(0, Math.min(100, smoothed));
          } else {
            // Keypoints missing – gentle drift toward neutral
            lastScoreRef.current = Math.max(0, lastScoreRef.current - 5);
            lastStateRef.current = "NEUTRAL_DRIFT";
          }
        } else {
          // No face – rapid drop
          lastScoreRef.current = Math.max(0, lastScoreRef.current - 15);
          lastStateRef.current = "DISTRACTED";
        }

        onScoreUpdateRef.current(
          lastScoreRef.current,
          stateLabel(lastStateRef.current)
        );
      } catch {
        // Ignore individual frame errors (model not ready, video paused, etc.)
      }

      scheduleNext();
    };

    const scheduleNext = () => {
      if (!loopRunning) return;
      // 500 ms throttle → ≈2 FPS inference rate
      timeoutRef.current = setTimeout(() => {
        animationRef.current = requestAnimationFrame(detectFace);
      }, 500);
    };

    if (isActive) {
      detectFace();
    }

    return () => {
      loopRunning = false;
      // Cancel pending timeout (memory leak fix)
      if (timeoutRef.current !== null) {
        clearTimeout(timeoutRef.current);
        timeoutRef.current = null;
      }
      cancelAnimationFrame(animationRef.current);
    };
  }, [isActive, videoRef]);

  // This component is logic-only; it renders no DOM nodes.
  return null;
};

export default FaceTrackerEdge;
