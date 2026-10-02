import os
import json
import shutil
import random

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSONL_PATH = os.path.join(ROOT_DIR, "TestData", "cheki_annotations.jsonl")
IMG_DIR = os.path.join(ROOT_DIR, "TestData", "images")
OUT_DIR = os.path.join(ROOT_DIR, "datasets", "cheki_obb")

for sub in ["images/train", "images/val", "labels/train", "labels/val"]:
    os.makedirs(os.path.join(OUT_DIR, sub), exist_ok=True)

lines = open(JSONL_PATH).read().strip().split('\n')
random.seed(42)
random.shuffle(lines)

split_idx = int(len(lines) * 0.85)
train_lines = lines[:split_idx]
val_lines = lines[split_idx:]

def process(lines, split_name):
    for line in lines:
        if not line: continue
        data = json.loads(line)
        fname = data['filename']
        w, h = data['width'], data['height']
        
        # normalized coordinates
        coords = []
        for pt in data['points']:
            coords.append(str(pt[0] / w))
            coords.append(str(pt[1] / h))
            
        label_str = "0 " + " ".join(coords)
        
        src_img = os.path.join(IMG_DIR, fname)
        if not os.path.exists(src_img):
            # Try without prefix if generated
            src_img = os.path.join(IMG_DIR, data['original_filename'])
            
        if os.path.exists(src_img):
            shutil.copy(src_img, os.path.join(OUT_DIR, "images", split_name, fname))
            with open(os.path.join(OUT_DIR, "labels", split_name, fname.rsplit('.', 1)[0] + ".txt"), "w") as f:
                f.write(label_str)

process(train_lines, "train")
process(val_lines, "val")

yaml_content = f"""
path: {OUT_DIR}
train: images/train
val: images/val
test:  # test images (optional)

names:
  0: cheki
"""
with open(os.path.join(OUT_DIR, "cheki.yaml"), "w") as f:
    f.write(yaml_content)

print(f"YOLO OBB dataset prepared at {OUT_DIR}")
