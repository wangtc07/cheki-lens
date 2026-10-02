import os
import json
import shutil
import random
import cv2

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSONL_PATH = os.path.join(ROOT_DIR, "TestData", "cheki_annotations.jsonl")
IMG_DIR = os.path.join(ROOT_DIR, "TestData", "images")

POSE_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_pose")
SEG_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_seg")

for base_dir in [POSE_DIR, SEG_DIR]:
    for sub in ["images/train", "images/val", "labels/train", "labels/val"]:
        os.makedirs(os.path.join(base_dir, sub), exist_ok=True)

with open(JSONL_PATH, "r") as f:
    lines = [l.strip() for l in f if l.strip()]

random.seed(42)
random.shuffle(lines)

split_idx = int(len(lines) * 0.85)
train_lines = lines[:split_idx]
val_lines = lines[split_idx:]

def build_data(item_lines, split_name):
    count = 0
    for l in item_lines:
        data = json.loads(l)
        fname = data['filename']
        w, h = data['width'], data['height']
        points = data['points'] # [[x, y], [x, y], [x, y], [x, y]]
        
        src_img = os.path.join(IMG_DIR, fname)
        if not os.path.exists(src_img):
            src_img = os.path.join(IMG_DIR, data.get('original_filename', ''))
        if not os.path.exists(src_img):
            continue
            
        # 1. Pose Label: class x_c y_c bbox_w bbox_h kx1 ky1 v1 kx2 ky2 v2 ...
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        min_x, max_x = max(0.0, min(xs)), min(float(w), max(xs))
        min_y, max_y = max(0.0, min(ys)), min(float(h), max(ys))
        
        box_w = (max_x - min_x) / w
        box_h = (max_y - min_y) / h
        box_xc = (min_x + max_x) / 2.0 / w
        box_yc = (min_y + max_y) / 2.0 / h
        
        kpts = []
        for p in points:
            kx = min(max(0.0, p[0] / w), 1.0)
            ky = min(max(0.0, p[1] / h), 1.0)
            kpts.extend([f"{kx:.6f}", f"{ky:.6f}", "2"])
            
        pose_label_str = f"0 {box_xc:.6f} {box_yc:.6f} {box_w:.6f} {box_h:.6f} " + " ".join(kpts)
        
        # 2. Seg Label: class x1 y1 x2 y2 x3 y3 x4 y4
        seg_pts = []
        for p in points:
            px = min(max(0.0, p[0] / w), 1.0)
            py = min(max(0.0, p[1] / h), 1.0)
            seg_pts.extend([f"{px:.6f}", f"{py:.6f}"])
        seg_label_str = "0 " + " ".join(seg_pts)
        
        # Copy image and write labels
        base_name = os.path.splitext(fname)[0]
        
        # Pose
        dst_img_pose = os.path.join(POSE_DIR, "images", split_name, fname)
        shutil.copy(src_img, dst_img_pose)
        with open(os.path.join(POSE_DIR, "labels", split_name, f"{base_name}.txt"), "w") as f_out:
            f_out.write(pose_label_str + "\n")
            
        # Seg
        dst_img_seg = os.path.join(SEG_DIR, "images", split_name, fname)
        shutil.copy(src_img, dst_img_seg)
        with open(os.path.join(SEG_DIR, "labels", split_name, f"{base_name}.txt"), "w") as f_out:
            f_out.write(seg_label_str + "\n")
            
        count += 1
    print(f"[{split_name}] Processed {count} items.")

build_data(train_lines, "train")
build_data(val_lines, "val")

# Pose YAML
pose_yaml = f"""path: {POSE_DIR}
train: images/train
val: images/val
kpt_shape: [4, 3] # 4 keypoints (TL, TR, BR, BL) with (x, y, visible)
names:
  0: cheki
"""
with open(os.path.join(POSE_DIR, "cheki_pose.yaml"), "w") as f:
    f.write(pose_yaml)

# Seg YAML
seg_yaml = f"""path: {SEG_DIR}
train: images/train
val: images/val
names:
  0: cheki
"""
with open(os.path.join(SEG_DIR, "cheki_seg.yaml"), "w") as f:
    f.write(seg_yaml)

print("Both datasets successfully prepared!")
