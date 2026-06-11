import React, { useEffect, useRef } from 'react';
import * as tf from '@tensorflow/tfjs';
import * as faceDetection from '@tensorflow-models/face-detection';

interface FaceTrackerEdgeProps {
  videoRef: React.RefObject<HTMLVideoElement>;
  isActive: boolean;
  onScoreUpdate: (score: number, state: string) => void;
}

export const FaceTrackerEdge: React.FC<FaceTrackerEdgeProps> = ({ videoRef, isActive, onScoreUpdate }) => {
  const detectorRef = useRef<faceDetection.FaceDetector | null>(null);
  const animationRef = useRef<number>(0);
  const lastScoreRef = useRef<number>(100);

  useEffect(() => {
    let isMounted = true;

    const initTF = async () => {
      try {
        await tf.ready();
        const model = faceDetection.SupportedModels.MediaPipeFaceDetector;
        const detectorConfig: any = {
          runtime: 'tfjs',
          maxFaces: 1,
        };
        const detector = await faceDetection.createDetector(model, detectorConfig);
        if (isMounted) detectorRef.current = detector;
      } catch (e) {
        console.error("TFJS Init Error:", e);
      }
    };

    initTF();

    return () => {
      isMounted = false;
      if (detectorRef.current) {
        detectorRef.current.dispose();
      }
    };
  }, []);

  useEffect(() => {
    const detectFace = async () => {
      if (!isActive || !videoRef.current || !detectorRef.current) {
        animationRef.current = requestAnimationFrame(detectFace);
        return;
      }

      if (videoRef.current.readyState >= 2) {
        try {
          const faces = await detectorRef.current.estimateFaces(videoRef.current, { flipHorizontal: false });
          
          if (faces.length > 0) {
            const face = faces[0];
            const keypoints = face.keypoints;
            
            // Simple heuristic for live edge tracking: 
            // If face is detected, we are generally focused. 
            // Can calculate yaw/pitch from keypoints if needed.
            const rightEye = keypoints.find((k: any) => k.name === 'rightEye');
            const leftEye = keypoints.find((k: any) => k.name === 'leftEye');
            const noseTip = keypoints.find((k: any) => k.name === 'noseTip');

            if (rightEye && leftEye && noseTip) {
               // Interpolate score to avoid jarring jumps
               lastScoreRef.current = Math.min(100, lastScoreRef.current + 5);
               onScoreUpdate(lastScoreRef.current, "Focused (Edge AI)");
            } else {
               lastScoreRef.current = Math.max(0, lastScoreRef.current - 10);
               onScoreUpdate(lastScoreRef.current, "Drifting (Edge AI)");
            }
          } else {
            // No face detected
            lastScoreRef.current = Math.max(0, lastScoreRef.current - 20);
            onScoreUpdate(lastScoreRef.current, "Away (Edge AI)");
          }
        } catch (error) {
          // Ignore frame drop errors
        }
      }
      
      // Delay to throttle tfjs slightly and not burn the parent's laptop
      setTimeout(() => {
        animationRef.current = requestAnimationFrame(detectFace);
      }, 500); // 2 FPS is plenty for telemetry
    };

    if (isActive) {
      detectFace();
    }

    return () => {
      cancelAnimationFrame(animationRef.current);
    };
  }, [isActive, onScoreUpdate, videoRef]);

  return null; // This is a logic-only component
};
