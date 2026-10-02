import os
import json
import random
from PIL import Image, ImageOps

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSONL_PATH = os.path.join(ROOT_DIR, "TestData", "cheki_annotations.jsonl")
IMG_DIR = os.path.join(ROOT_DIR, "TestData", "images")

POSE_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_pose")
SEG_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_seg")

for base_dir in [POSE_DIR, SEG_DIR]:
    for sub in ["images/train", "images/val", "labels/train", "labels/val"]:
        p = os.path.join(base_dir, sub)
        os.makedirs(p, exist_ok=True)
        # Clean existing files
        for f in os.listdir(p):
            os.remove(os.path.join(p, f))

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
        points = data['points']
        
        src_img_path = os.path.join(IMG_DIR, fname)
        if not os.path.exists(src_img_path):
            src_img_path = os.path.join(IMG_DIR, data.get('original_filename', ''))
        if not os.path.exists(src_img_path):
            continue
            
        try:
            # 物理轉正像素，徹底消除 EXIF 翻轉暗坑
            raw_img = Image.open(src_img_path)
            trans_img = ImageOps.exif_transpose(raw_img)
            w, h = trans_img.size
        except Exception as e:
            print(f"Error loading {src_img_path}: {e}")
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
        
        base_name = os.path.splitext(fname)[0]
        
        # 保存物理轉正後的影像，確保像素與標註完全 1:1
        dst_img_pose = os.path.join(POSE_DIR, "images", split_name, f"{base_name}.jpg")
        dst_img_seg = os.path.join(SEG_DIR, "images", split_name, f"{base_name}.jpg")
        
        trans_img.convert("RGB").save(dst_img_pose, "JPEG", quality=95)
        trans_img.convert("RGB").save(dst_img_seg, "JPEG", quality=95)
        
        with open(os.path.join(POSE_DIR, "labels", split_name, f"{base_name}.txt"), "w") as f_out:
            f_out.write(pose_label_str + "\n")
            
        with open(os.path.join(SEG_DIR, "labels", split_name, f"{base_name}.txt"), "w") as f_out:
            f_out.write(seg_label_str + "\n")
            
        count += 1
    print(f"[{split_name}] Cleaned & Processed {count} items.")

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

print("Both clean datasets ready!")
