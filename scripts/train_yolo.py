from ultralytics import YOLO

def main():
    # Load YOLOv8n-OBB model
    model = YOLO("yolov8n-obb.pt")
    
    # Train
    print("Training YOLO-OBB...")
    model.train(data="/Users/tcwang/Documents/ChekiLens/datasets/cheki_obb/cheki.yaml", epochs=30, imgsz=416, batch=16, device="mps")
    
    # Export to CoreML
    print("Exporting to CoreML...")
    model.export(format="coreml", nms=True)
    
if __name__ == "__main__":
    main()
