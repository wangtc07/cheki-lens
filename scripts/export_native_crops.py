import os, json, cv2, numpy as np

ROOT_DIR = "."
VAL_IMAGES_DIR = "datasets/cheki_pose/images/val"
OUT_DIR = "TestData/benchmark_output_native"
NATIVE_JSON = "/tmp/native_clean_val.json"

os.makedirs(OUT_DIR, exist_ok=True)

with open(NATIVE_JSON) as f:
    preds = json.load(f)

def order_points(pts):
    pts = np.array(pts, dtype=np.float32)
    rect = np.zeros((4, 2), dtype=np.float32)
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)] # TL
    rect[2] = pts[np.argmax(s)] # BR
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)] # TR
    rect[3] = pts[np.argmax(diff)] # BL
    return rect

count = 0
for fname, pts in preds.items():
    img_path = os.path.join(VAL_IMAGES_DIR, fname)
    if not os.path.exists(img_path): continue
    
    img = cv2.imread(img_path)
    if img is None: continue
    
    rect = order_points(pts)
    # Target size: Instax Mini ratio (86:54 -> 860x540)
    dst_w, dst_h = 540, 860
    dst_pts = np.array([[0, 0], [dst_w, 0], [dst_w, dst_h], [0, dst_h]], dtype=np.float32)
    
    M = cv2.getPerspectiveTransform(rect, dst_pts)
    warped = cv2.warpPerspective(img, M, (dst_w, dst_h))
    
    out_path = os.path.join(OUT_DIR, f"{os.path.splitext(fname)[0]}_native.jpg")
    cv2.imwrite(out_path, warped)
    count += 1

print(f"Successfully exported {count} Apple Native cropped images to {OUT_DIR}")
