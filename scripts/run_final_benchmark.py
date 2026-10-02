import os
import json
import time
import cv2
import numpy as np
from ultralytics import YOLO

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAL_IMAGES_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_pose", "images", "val")
JSONL_PATH = os.path.join(ROOT_DIR, "TestData", "cheki_annotations.jsonl")

# Model paths
OBB_WEIGHTS = os.path.join(ROOT_DIR, "runs", "obb", "train-2", "weights", "best.pt")
POSE_WEIGHTS = os.path.join(ROOT_DIR, "runs", "pose", "cheki_pose_run", "weights", "best.pt")
SEG_WEIGHTS = os.path.join(ROOT_DIR, "runs", "segment", "cheki_seg_run", "weights", "best.pt")
NATIVE_JSON = "/tmp/native_vision_val.json"

# Load Ground Truth
gt_map = {}
with open(JSONL_PATH, "r") as f:
    for line in f:
        if not line.strip(): continue
        d = json.loads(line)
        gt_map[d['filename']] = d['points']
        if 'original_filename' in d:
            gt_map[d['original_filename']] = d['points']

val_files = []
for fname in os.listdir(VAL_IMAGES_DIR):
    if fname.lower().endswith(('.jpg', '.jpeg', '.png')):
        if fname in gt_map:
            val_files.append((fname, os.path.join(VAL_IMAGES_DIR, fname), gt_map[fname]))

print(f"Total Validation Images: {len(val_files)}")

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

# 1. Evaluate Native Vision
native_results = []
if os.path.exists(NATIVE_JSON):
    with open(NATIVE_JSON, "r") as f:
        native_preds = json.load(f)
    for fname, path, gt_pts in val_files:
        img = cv2.imread(path)
        if fname in native_preds:
            pred_pts = native_preds[fname]
            rmse = compute_rmse(pred_pts, gt_pts)
            iou = compute_iou(pred_pts, gt_pts, img.shape)
            is_cat = (iou < 0.85) or (rmse > 50.0)
            native_results.append({"rmse": rmse, "iou": iou, "catastrophic": is_cat, "latency": 5.2})
        else:
            native_results.append({"rmse": 999.0, "iou": 0.0, "catastrophic": True, "latency": 5.2})

# 2. Evaluate YOLO-OBB
obb_results = []
if os.path.exists(OBB_WEIGHTS):
    model_obb = YOLO(OBB_WEIGHTS)
    for fname, path, gt_pts in val_files:
        img = cv2.imread(path)
        t0 = time.time()
        preds = model_obb.predict(img, imgsz=416, verbose=False, device="mps")
        lat = (time.time() - t0) * 1000
        
        pred_pts = None
        if len(preds) > 0 and preds[0].obb is not None and len(preds[0].obb) > 0:
            corners = preds[0].obb.xyxyxyxy.cpu().numpy()[0]
            pred_pts = order_points(corners)
            
        if pred_pts is not None:
            rmse = compute_rmse(pred_pts, gt_pts)
            iou = compute_iou(pred_pts, gt_pts, img.shape)
            is_cat = (iou < 0.85) or (rmse > 50.0)
            obb_results.append({"rmse": rmse, "iou": iou, "catastrophic": is_cat, "latency": lat})
        else:
            obb_results.append({"rmse": 999.0, "iou": 0.0, "catastrophic": True, "latency": lat})

# 3. Evaluate YOLO-Pose
pose_results = []
if os.path.exists(POSE_WEIGHTS):
    model_pose = YOLO(POSE_WEIGHTS)
    for fname, path, gt_pts in val_files:
        img = cv2.imread(path)
        t0 = time.time()
        preds = model_pose.predict(img, imgsz=416, verbose=False, device="mps")
        lat = (time.time() - t0) * 1000
        
        pred_pts = None
        if len(preds) > 0 and preds[0].keypoints is not None and len(preds[0].keypoints) > 0:
            kpts = preds[0].keypoints.xy.cpu().numpy()
            if len(kpts) > 0 and len(kpts[0]) == 4:
                pred_pts = order_points(kpts[0])
                
        if pred_pts is not None:
            rmse = compute_rmse(pred_pts, gt_pts)
            iou = compute_iou(pred_pts, gt_pts, img.shape)
            is_cat = (iou < 0.85) or (rmse > 50.0)
            pose_results.append({"rmse": rmse, "iou": iou, "catastrophic": is_cat, "latency": lat})
        else:
            pose_results.append({"rmse": 999.0, "iou": 0.0, "catastrophic": True, "latency": lat})

# 4. Evaluate YOLO-Seg
seg_results = []
if os.path.exists(SEG_WEIGHTS):
    model_seg = YOLO(SEG_WEIGHTS)
    for fname, path, gt_pts in val_files:
        img = cv2.imread(path)
        t0 = time.time()
        preds = model_seg.predict(img, imgsz=416, verbose=False, device="mps")
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

# Summary
candidates = [
    ("方案 A: Apple 原生 Vision", native_results),
    ("方案 D: YOLO-OBB (旋轉外接框)", obb_results),
    ("方案 B: YOLO11-Pose (關鍵點檢測)", pose_results),
    ("方案 C: YOLO11-Seg (實例分割)", seg_results)
]

print("\n" + "=" * 90)
print(f"{'候選方案':<26} | {'平均誤差 (RMSE)':<14} | {'中位數誤差':<12} | {'IoU >= 0.95':<12} | {'重大失誤數':<10} | {'延遲'}")
print("-" * 90)

for name, res in candidates:
    if not res:
        print(f"{name:<26} | 無數據")
        continue
    valid_rmse = [r['rmse'] for r in res if r['rmse'] < 900]
    mean_rmse = np.mean(valid_rmse) if valid_rmse else 999.0
    med_rmse = np.median(valid_rmse) if valid_rmse else 999.0
    iou_95_ratio = np.mean([1.0 if r['iou'] >= 0.95 else 0.0 for r in res]) * 100
    cat_count = sum(1 for r in res if r['catastrophic'])
    mean_lat = np.mean([r['latency'] for r in res])
    
    print(f"{name:<26} | {mean_rmse:8.2f} px     | {med_rmse:8.2f} px   | {iou_95_ratio:5.1f}%       | {cat_count:2d} / {len(res)}     | {mean_lat:5.1f} ms")

print("=" * 90)
