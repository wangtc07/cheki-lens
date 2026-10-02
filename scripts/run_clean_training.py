import os
import time
from ultralytics import YOLO

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POSE_YAML = os.path.join(ROOT_DIR, "datasets", "cheki_pose", "cheki_pose.yaml")
SEG_YAML = os.path.join(ROOT_DIR, "datasets", "cheki_seg", "cheki_seg.yaml")

print("==================================================")
print("🚀 [1/2] Training YOLO11-Pose (Option B) on Clean Data")
print("==================================================")
t0 = time.time()
pose_model = YOLO("yolo11n-pose.pt")
pose_model.train(
    data=POSE_YAML,
    epochs=30,
    imgsz=416,
    batch=16,
    device="mps",
    plots=True,
    save=True,
    name="cheki_pose_clean",
    exist_ok=True
)
print(f"✅ Pose training finished in {time.time() - t0:.1f}s")

print("==================================================")
print("🚀 [2/2] Training YOLO11-Seg (Option C) on Clean Data")
print("==================================================")
t1 = time.time()
seg_model = YOLO("yolo11n-seg.pt")
seg_model.train(
    data=SEG_YAML,
    epochs=30,
    imgsz=416,
    batch=16,
    device="mps",
    plots=True,
    save=True,
    name="cheki_seg_clean",
    exist_ok=True
)
print(f"✅ Seg training finished in {time.time() - t1:.1f}s")

print("🎉 Both models trained on 100% clean, transposed data!")
