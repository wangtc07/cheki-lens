import os
import json
import cv2
import numpy as np

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
IMAGES_DIR   = os.path.join(PROJECT_ROOT, "TestData", "images")
ANNOT_FILE   = os.path.join(PROJECT_ROOT, "TestData", "cheki_annotations.jsonl")
OUTPUT_DIR   = os.path.join(PROJECT_ROOT, "TestData", "output_ground_truth")

os.makedirs(OUTPUT_DIR, exist_ok=True)

def dist(p1, p2):
    return np.sqrt((p1[0] - p2[0])**2 + (p1[1] - p2[1])**2)

def process_image(record):
    filename = record["filename"]
    pts = record["points"]
    img_path = os.path.join(IMAGES_DIR, filename)
    out_path = os.path.join(OUTPUT_DIR, filename)
    
    img = cv2.imread(img_path)
    if img is None:
        print(f"[Error] 無法讀取: {filename}")
        return
        
    tl, tr, br, bl = pts[0], pts[1], pts[2], pts[3]
    
    # Calculate average width and height
    width_a = dist(tl, tr)
    width_b = dist(bl, br)
    w = (width_a + width_b) / 2
    
    height_a = dist(tl, bl)
    height_b = dist(tr, br)
    h = (height_a + height_b) / 2
    
    ratio = h / w
    
    # Determine format and output size
    if ratio > 1.35:
        # Mini (54x86) -> Aspect ~ 1.59
        out_w, out_h = 810, 1290
        fmt = "Mini"
    elif ratio < 0.95:
        # Wide (108x86) -> Aspect ~ 0.79
        out_w, out_h = 1620, 1290
        fmt = "Wide"
    else:
        # Square (72x86) -> Aspect ~ 1.19
        out_w, out_h = 1080, 1290
        fmt = "Square"
        
    src_pts = np.array([tl, tr, br, bl], dtype="float32")
    dst_pts = np.array([
        [0, 0],
        [out_w - 1, 0],
        [out_w - 1, out_h - 1],
        [0, out_h - 1]
    ], dtype="float32")
    
    # Warping
    M = cv2.getPerspectiveTransform(src_pts, dst_pts)
    warped = cv2.warpPerspective(img, M, (out_w, out_h), flags=cv2.INTER_LANCZOS4)
    
    cv2.imwrite(out_path, warped)
    print(f"✅ [{fmt}] 成功裁切: {filename}")

def main():
    if not os.path.exists(ANNOT_FILE):
        print(f"Error: {ANNOT_FILE} 不存在")
        return
        
    records = []
    with open(ANNOT_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
                
    print(f"📂 準備根據標註結果裁切 {len(records)} 張圖片...")
    print(f"輸出目錄: {OUTPUT_DIR}\n")
    
    for rec in records:
        process_image(rec)
        
    print(f"\n🎉 裁切完成！所有結果已存至: {OUTPUT_DIR}")
    print("您可以打開資料夾，切換到『圖示檢視 (Gallery)』，快速瀏覽您完美標註的結果！")

if __name__ == "__main__":
    main()
