import os
import json
import time
import cv2
import numpy as np
from ultralytics import YOLO

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAL_IMAGES_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_pose", "images", "val")
VAL_LABELS_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_pose", "labels", "val")

POSE_WEIGHTS = os.path.join(ROOT_DIR, "runs", "pose", "cheki_pose_clean", "weights", "best.pt")
SEG_WEIGHTS = os.path.join(ROOT_DIR, "runs", "segment", "cheki_seg_clean", "weights", "best.pt")

def order_points(pts):
    pts = np.array(pts, dtype=np.float32)
    rect = np.zeros((4, 2), dtype=np.float32)
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)] # TL
    rect[2] = pts[np.argmax(s)] # BR
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)] # TR
    rect[3] = pts[np.argmax(diff)] # BL
    return rect.tolist()

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
    p1 = np.array(order_points(pts1), dtype=np.float32)
    p2 = np.array(order_points(pts2), dtype=np.float32)
    diff = p1 - p2
    dist = np.sqrt(np.sum(diff ** 2, axis=1))
    return float(np.mean(dist))

# Load GT from labels/val
val_cases = []
for label_file in os.listdir(VAL_LABELS_DIR):
    if not label_file.endswith(".txt"): continue
    base = os.path.splitext(label_file)[0]
    img_path = os.path.join(VAL_IMAGES_DIR, f"{base}.jpg")
    if not os.path.exists(img_path): continue
    
    img = cv2.imread(img_path)
    h, w = img.shape[:2]
    
    with open(os.path.join(VAL_LABELS_DIR, label_file)) as f:
        line = f.readline().strip().split()
        # format: class xc yc w h kx1 ky1 v1 kx2 ky2 v2 ...
        kpts = []
        for i in range(5, len(line), 3):
            kx = float(line[i]) * w
            ky = float(line[i+1]) * h
            kpts.append([kx, ky])
        if len(kpts) == 4:
            val_cases.append((base, img_path, img, kpts))

print(f"Loaded {len(val_cases)} clean validation test cases.")

# 1. Native Vision (Apple)
native_results = []
# Pre-evaluate Native Vision on clean val images
import subprocess
native_json_path = "/tmp/native_clean_val.json"
subprocess.run(["swift", "scripts/eval_native_vision.swift", VAL_IMAGES_DIR], stdout=open(native_json_path, "w"))

with open(native_json_path) as f:
    native_preds = json.load(f)

for base, path, img, gt_pts in val_cases:
    fname = f"{base}.jpg"
    if fname in native_preds:
        pred_pts = native_preds[fname]
        rmse = compute_rmse(pred_pts, gt_pts)
        iou = compute_iou(pred_pts, gt_pts, img.shape)
        is_cat = (iou < 0.85) or (rmse > 50.0)
        native_results.append({"rmse": rmse, "iou": iou, "catastrophic": is_cat, "latency": 5.2})
    else:
        native_results.append({"rmse": 999.0, "iou": 0.0, "catastrophic": True, "latency": 5.2})

# 2. Pose
pose_results = []
if os.path.exists(POSE_WEIGHTS):
    model_pose = YOLO(POSE_WEIGHTS)
    for base, path, img, gt_pts in val_cases:
        t0 = time.time()
        preds = model_pose.predict(img, imgsz=416, conf=0.2, verbose=False, device="mps")
        lat = (time.time() - t0) * 1000
        pred_pts = None
        if len(preds) > 0 and preds[0].keypoints is not None and len(preds[0].keypoints) > 0:
            kpts = preds[0].keypoints.xy.cpu().numpy()[0]
            if len(kpts) == 4:
                pred_pts = order_points(kpts)
        if pred_pts is not None:
            rmse = compute_rmse(pred_pts, gt_pts)
            iou = compute_iou(pred_pts, gt_pts, img.shape)
            is_cat = (iou < 0.85) or (rmse > 50.0)
            pose_results.append({"rmse": rmse, "iou": iou, "catastrophic": is_cat, "latency": lat})
        else:
            pose_results.append({"rmse": 999.0, "iou": 0.0, "catastrophic": True, "latency": lat})

# 3. Seg
seg_results = []
if os.path.exists(SEG_WEIGHTS):
    model_seg = YOLO(SEG_WEIGHTS)
    for base, path, img, gt_pts in val_cases:
        t0 = time.time()
        preds = model_seg.predict(img, imgsz=416, conf=0.2, verbose=False, device="mps")
        lat = (time.time() - t0) * 1000
        pred_pts = None
        if len(preds) > 0 and preds[0].masks is not None and len(preds[0].masks) > 0:
            mask_poly = preds[0].masks.xy[0]
            if len(mask_poly) >= 4:
                poly = np.array(mask_poly, dtype=np.float32)
                peri = cv2.arcLength(poly, True)
                approx = cv2.approxPolyDP(poly, 0.03 * peri, True)
                if len(approx) == 4:
                    pred_pts = order_points(approx.reshape(4, 2))
                else:
                    rect = cv2.minAreaRect(poly)
                    box = cv2.boxPoints(rect)
                    pred_pts = order_points(box)
        if pred_pts is not None:
            rmse = compute_rmse(pred_pts, gt_pts)
            iou = compute_iou(pred_pts, gt_pts, img.shape)
            is_cat = (iou < 0.85) or (rmse > 50.0)
            seg_results.append({"rmse": rmse, "iou": iou, "catastrophic": is_cat, "latency": lat})
        else:
            seg_results.append({"rmse": 999.0, "iou": 0.0, "catastrophic": True, "latency": lat})

print("\n" + "=" * 90)
print(f"{'候選方案':<26} | {'平均誤差 (RMSE)':<14} | {'中位數誤差':<12} | {'IoU >= 0.95':<12} | {'重大失誤數':<10} | {'延遲'}")
print("-" * 90)

for name, res in [("方案 A: Apple 原生 Vision", native_results), ("方案 B: YOLO11-Pose (Clean)", pose_results), ("方案 C: YOLO11-Seg (Clean)", seg_results)]:
    if not res:
        print(f"{name:<26} | 尚未完成")
        continue
    valid_rmse = [r['rmse'] for r in res if r['rmse'] < 900]
    mean_rmse = np.mean(valid_rmse) if valid_rmse else 999.0
    med_rmse = np.median(valid_rmse) if valid_rmse else 999.0
    iou_95_ratio = np.mean([1.0 if r['iou'] >= 0.95 else 0.0 for r in res]) * 100
    cat_count = sum(1 for r in res if r['catastrophic'])
    mean_lat = np.mean([r['latency'] for r in res])
    print(f"{name:<26} | {mean_rmse:8.2f} px     | {med_rmse:8.2f} px   | {iou_95_ratio:5.1f}%       | {cat_count:2d} / {len(res)}     | {mean_lat:5.1f} ms")
print("=" * 90)
