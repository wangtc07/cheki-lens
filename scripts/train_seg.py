import os
from ultralytics import YOLO

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_YAML = os.path.join(ROOT_DIR, "datasets", "cheki_seg", "cheki_seg.yaml")

def main():
    print("=== Training YOLO11-Seg (Option C) ===")
    model = YOLO("yolo11n-seg.pt")
    model.train(
        data=DATA_YAML,
        epochs=35,
        imgsz=416,
        batch=16,
        device="mps",
        plots=True,
        save=True,
        name="cheki_seg_run"
    )
    print("YOLO11-Seg training complete!")

if __name__ == "__main__":
    main()
