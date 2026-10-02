import os
import json
import cv2
import numpy as np
import random
from concurrent.futures import ThreadPoolExecutor

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
IMAGES_DIR = os.path.join(PROJECT_ROOT, "TestData", "images")
ANNOT_FILE = os.path.join(PROJECT_ROOT, "TestData", "cheki_annotations.jsonl")

# ML Dataset Paths
ML_DATA_DIR = os.path.join(PROJECT_ROOT, "TestData", "ml_dataset")
ML_IMAGES_DIR = os.path.join(ML_DATA_DIR, "images")
ML_LABELS = os.path.join(ML_DATA_DIR, "labels.json")

os.makedirs(ML_IMAGES_DIR, exist_ok=True)

TARGET_SIZE = 256
NUM_AUGMENTATIONS = 5 # 1 original + 4 augmented

def random_augment(img, pts):
    h, w = img.shape[:2]
    
    # 1. Random Brightness/Contrast
    alpha = random.uniform(0.7, 1.3)
    beta = random.uniform(-30, 30)
    img_aug = cv2.convertScaleAbs(img, alpha=alpha, beta=beta)
    
    # 2. Random Rotation (-15 to +15 deg)
    angle = random.uniform(-15, 15)
    center = (w/2, h/2)
    M_rot = cv2.getRotationMatrix2D(center, angle, 1.0)
    img_aug = cv2.warpAffine(img_aug, M_rot, (w, h), borderValue=(0,0,0))
    
    pts_ones = np.hstack([pts, np.ones((4,1))])
    pts_rot = M_rot.dot(pts_ones.T).T
    
    # 3. Random Translation (-10% to +10%)
    tx = random.uniform(-w*0.1, w*0.1)
    ty = random.uniform(-h*0.1, h*0.1)
    M_trans = np.float32([[1, 0, tx], [0, 1, ty]])
    img_aug = cv2.warpAffine(img_aug, M_trans, (w, h), borderValue=(0,0,0))
    pts_trans = pts_rot + np.array([tx, ty])
    
    # 4. Random Perspective (Simulate 3D Tilt)
    p1 = np.float32([[0,0], [w,0], [w,h], [0,h]])
    mx = w * 0.1
    my = h * 0.1
    p2 = np.float32([
        [random.uniform(0, mx), random.uniform(0, my)],
        [w - random.uniform(0, mx), random.uniform(0, my)],
        [w - random.uniform(0, mx), h - random.uniform(0, my)],
        [random.uniform(0, mx), h - random.uniform(0, my)]
    ])
    M_persp = cv2.getPerspectiveTransform(p1, p2)
    img_aug = cv2.warpPerspective(img_aug, M_persp, (w, h), borderValue=(0,0,0))
    
    pts_trans_ones = np.hstack([pts_trans, np.ones((4,1))])
    pts_persp_homo = M_persp.dot(pts_trans_ones.T).T
    pts_persp = pts_persp_homo[:, :2] / pts_persp_homo[:, 2:]
    
    return img_aug, pts_persp

def process_image(record):
    filename = record["filename"]
    pts = np.array(record["points"], dtype=np.float32)
    img_path = os.path.join(IMAGES_DIR, filename)
    
    img = cv2.imread(img_path)
    if img is None:
        return []
        
    results = []
    base_name = os.path.splitext(filename)[0]
    
    for i in range(NUM_AUGMENTATIONS):
        if i == 0:
            # First one is just the original (resized)
            aug_img, aug_pts = img.copy(), pts.copy()
        else:
            aug_img, aug_pts = random_augment(img, pts)
            
        # Resize to TARGET_SIZE x TARGET_SIZE
        h, w = aug_img.shape[:2]
        resized_img = cv2.resize(aug_img, (TARGET_SIZE, TARGET_SIZE), interpolation=cv2.INTER_AREA)
        
        scale_x = TARGET_SIZE / w
        scale_y = TARGET_SIZE / h
        final_pts = aug_pts * np.array([scale_x, scale_y])
        
        # Normalize points to [0.0, 1.0] for PyTorch training
        norm_pts = final_pts / TARGET_SIZE
        
        out_filename = f"{base_name}_aug{i}.jpg"
        out_path = os.path.join(ML_IMAGES_DIR, out_filename)
        cv2.imwrite(out_path, resized_img)
        
        results.append({
            "image": out_filename,
            "keypoints": norm_pts.tolist() # [[x1, y1], [x2, y2], ...]
        })
        
    return results

def main():
    if not os.path.exists(ANNOT_FILE):
        print(f"Error: {ANNOT_FILE} 不存在")
        return
        
    records = []
    with open(ANNOT_FILE, 'r') as f:
        for line in f:
            if line.strip():
                records.append(json.loads(line))
                
    print(f"🔄 開始擴充資料：從 {len(records)} 張圖片產生 {len(records)*NUM_AUGMENTATIONS} 張訓練集...")
    
    all_ml_data = []
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(process_image, rec) for rec in records]
        for idx, f in enumerate(futures):
            res = f.result()
            all_ml_data.extend(res)
            if (idx + 1) % 50 == 0:
                print(f"   已處理 {idx + 1} / {len(records)} 張...")
                
    with open(ML_LABELS, 'w') as f:
        json.dump(all_ml_data, f, indent=2)
        
    print(f"✅ 資料擴充完成！")
    print(f"總共產生了 {len(all_ml_data)} 張機器學習訓練照片。")
    print(f"檔案存放於: {ML_DATA_DIR}")

if __name__ == "__main__":
    main()
