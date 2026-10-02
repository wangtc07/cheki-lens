import os, cv2, numpy as np
from ultralytics import YOLO

target_files = ["DSCF0024.JPG", "DSCF0026.JPG", "DSCF0034.JPG", "DSCF0032.JPG", "DSCF0042.JPG", "IMG_6529.jpeg"]
IMG_DIR = "TestData/images"
OUT_DIR = "TestData/benchmark_output_yolo_backs"
os.makedirs(OUT_DIR, exist_ok=True)

model = YOLO("runs/pose/cheki_pose_clean/weights/best.pt")

for tf in target_files:
    p = os.path.join(IMG_DIR, tf)
    if not os.path.exists(p): continue
    
    img = cv2.imread(p)
    if img is None: continue
    
    res = model.predict(p, conf=0.15, verbose=False)
    boxes = res[0].boxes
    if len(boxes) > 0:
        b = boxes.xyxy[0].cpu().numpy().astype(int)
        x1, y1, x2, y2 = max(0, b[0]), max(0, b[1]), min(img.shape[1], b[2]), min(img.shape[0], b[3])
        cropped = img[y1:y2, x1:x2]
        
        # Resize to standard aspect ratio preview
        out_path = os.path.join(OUT_DIR, f"{os.path.splitext(tf)[0]}_yolo_crop.jpg")
        cv2.imwrite(out_path, cropped)
        print(f"Exported: {out_path} ({x2-x1}x{y2-y1})")

print("All YOLO backside crops exported!")
