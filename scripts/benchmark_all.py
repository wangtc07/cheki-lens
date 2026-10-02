import os
import json
import time
import cv2
import numpy as np
from ultralytics import YOLO

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAL_LABELS_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_pose", "labels", "val")
VAL_IMAGES_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_pose", "images", "val")

POSE_WEIGHTS = os.path.join(ROOT_DIR, "runs", "pose", "cheki_pose_run", "weights", "best.pt")
SEG_WEIGHTS = os.path.join(ROOT_DIR, "runs", "seg", "cheki_seg_run", "weights", "best.pt")

def compute_iou(pts1, pts2, shape):
    h, w = shape[:2]
    m1 = np.zeros((h, w), dtype=np.uint8)
    m2 = np.zeros((h, w), dtype=np.uint8)
    
    p1 = np.array(pts1, dtype=np.int32).reshape((-1, 1, 2))
    p2 = np.array(pts2, dtype=np.int32).reshape((-1, 1, 2))
    
    cv2.fillPoly(m1, [p1], 1)
    cv2.fillPoly(m2, [p2], 1)
    
    intersection = np.logical_and(m1, m2).sum()
    union = np.logical_or(m1, m2).sum()
    if union == 0:
        return 0.0
    return float(intersection / union)

def compute_rmse(pts1, pts2):
    p1 = np.array(pts1, dtype=np.float32)
    p2 = np.array(pts2, dtype=np.float32)
    diff = p1 - p2
    dist = np.sqrt(np.sum(diff ** 2, axis=1))
    return float(np.mean(dist))

def order_points(pts):
    # Sort: TL, TR, BR, BL
    pts = np.array(pts, dtype=np.float32)
    rect = np.zeros((4, 2), dtype=np.float32)
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)] # TL
    rect[2] = pts[np.argmax(s)] # BR
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)] # TR
    rect[3] = pts[np.argmax(diff)] # BL
    return rect.tolist()

def eval_pose_model(model_path, val_files):
    if not os.path.exists(model_path):
        return None
    model = YOLO(model_path)
    results = []
    
    for img_path, gt_pts in val_files:
        img = cv2.imread(img_path)
        h, w = img.shape[:2]
        
        t0 = time.time()
        preds = model.predict(img, imgsz=416, verbose=False, device="mps")
        lat = (time.time() - t0) * 1000
        
        pred_pts = None
        if len(preds) > 0 and preds[0].keypoints is not None and len(preds[0].keypoints) > 0:
            kpts = preds[0].keypoints.xy.cpu().numpy()
            if len(kpts) > 0 and len(kpts[0]) == 4:
                pred_pts = order_points(kpts[0])
                
        if pred_pts is not None:
            rmse = compute_rmse(pred_pts, gt_pts)
            iou = compute_iou(pred_pts, gt_pts, img.shape)
            is_catastrophic = (iou < 0.85) or (rmse > 50.0)
            results.append({
                "rmse": rmse,
                "iou": iou,
                "latency": lat,
                "catastrophic": is_catastrophic
            })
        else:
            results.append({
                "rmse": 999.0,
                "iou": 0.0,
                "latency": lat,
                "catastrophic": True
            })
    return results

def eval_seg_model(model_path, val_files):
    if not os.path.exists(model_path):
        return None
    model = YOLO(model_path)
    results = []
    
    for img_path, gt_pts in val_files:
        img = cv2.imread(img_path)
        h, w = img.shape[:2]
        
        t0 = time.time()
        preds = model.predict(img, imgsz=416, verbose=False, device="mps")
        lat = (time.time() - t0) * 1000
        
        pred_pts = None
        if len(preds) > 0 and preds[0].masks is not None and len(preds[0].masks) > 0:
            mask_poly = preds[0].masks.xy[0]
            if len(mask_poly) >= 4:
                # Approximate 4 corners using polygon approx
                poly = np.array(mask_poly, dtype=np.float32)
                peri = cv2.arcLength(poly, True)
                approx = cv2.approxPolyDP(poly, 0.04 * peri, True)
                if len(approx) == 4:
                    pred_pts = order_points(approx.reshape(4, 2))
                else:
                    # Minimum area rect fallback
                    rect = cv2.minAreaRect(poly)
                    box = cv2.boxPoints(rect)
                    pred_pts = order_points(box)
                    
        if pred_pts is not None:
            rmse = compute_rmse(pred_pts, gt_pts)
            iou = compute_iou(pred_pts, gt_pts, img.shape)
            is_catastrophic = (iou < 0.85) or (rmse > 50.0)
            results.append({
                "rmse": rmse,
                "iou": iou,
                "latency": lat,
                "catastrophic": is_catastrophic
            })
        else:
            results.append({
                "rmse": 999.0,
                "iou": 0.0,
                "latency": lat,
                "catastrophic": True
            })
    return results

print("Benchmark evaluation script ready!")
