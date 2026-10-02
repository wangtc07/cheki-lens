import os, cv2, numpy as np

# Coordinates from Swift OCR detection
cases = [
    ("user_uploaded_back", "/Users/tcwang/.gemini/antigravity/brain/2321a9b0-59c1-4387-8354-5efce9f3dcdf/.user_uploaded/media_1790913536053.jpg", 
     [[407.5, 173.7], [593.5, 173.7], [593.5, 866.4], [407.5, 866.4]]),
    ("193431_DSCF1434", "TestData/images/193431_DSCF1434.JPG", 
     [[274.5, 48.9], [570.5, 48.9], [570.5, 486.9], [274.5, 486.9]]),
    ("DSCF0026", "TestData/images/DSCF0026.JPG", 
     [[301.2, 54.5], [2624.4, 54.5], [2624.4, 3857.0], [301.2, 3857.0]]),
    ("DSCF0032", "TestData/images/DSCF0032.JPG", 
     [[275.3, 54.2], [2858.0, 54.2], [2858.0, 4200.7], [275.3, 4200.7]]),
    ("DSCF0024", "TestData/images/DSCF0024.JPG", 
     [[1049.3, 109.4], [2356.4, 109.4], [2356.4, 4038.0], [1049.3, 4038.0]]),
]

out_dir = "TestData/benchmark_output_ocr_back"
os.makedirs(out_dir, exist_ok=True)

dst_w, dst_h = 540, 860
dst_pts = np.array([[0, 0], [dst_w, 0], [dst_w, dst_h], [0, dst_h]], dtype=np.float32)

for name, path, pts in cases:
    if not os.path.exists(path): continue
    img = cv2.imread(path)
    if img is None: continue
    
    src_pts = np.array(pts, dtype=np.float32)
    M = cv2.getPerspectiveTransform(src_pts, dst_pts)
    warped = cv2.warpPerspective(img, M, (dst_w, dst_h))
    
    out_file = os.path.join(out_dir, f"{name}_ocr_crop.jpg")
    cv2.imwrite(out_file, warped)
    print(f"Exported: {out_file}")

print("All OCR Backside cropped images exported!")
