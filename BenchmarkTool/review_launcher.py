#!/usr/bin/env python3
"""
ChekiLens Corner Review Launcher
---------------------------------
Uses py-gif's web_ui.py to manually review and adjust Vision-detected corners.

Usage:
    python3 BenchmarkTool/review_launcher.py [--all] [--rmse-threshold 15]

Options:
    --all               Review all 72 images (default: only ⚠️ images with RMSE > threshold)
    --rmse-threshold N  RMSE pixel threshold for filtering (default: 15)
    --output PATH       Where to save corrected annotations (default: TestData/manual_corrections.jsonl)

After you finish adjusting corners in the browser and click "Save & Crop All",
the script will:
  1. Save corrected corner points to manual_corrections.jsonl
  2. Print a summary of which images were adjusted
  3. (Optional) Re-run the benchmark to measure the improvement
"""

import sys
import os
import json
import subprocess
import tempfile
import argparse

# ── Path Setup ──────────────────────────────────────────────────────────────
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
TEST_DATA    = os.path.join(PROJECT_ROOT, "TestData")
IMAGES_DIR   = os.path.join(TEST_DATA, "images")
ANNOT_FILE   = os.path.join(TEST_DATA, "cheki_annotations.jsonl")
OUTPUT_FILE  = os.path.join(TEST_DATA, "manual_corrections.jsonl")

# py-gif web_ui path
WEB_UI_DIR   = "/Users/tcwang/Documents/py-gif/src/image_process"
WEB_UI_PATH  = os.path.join(WEB_UI_DIR, "web_ui.py")

# Swift binary for exporting Vision corners
EXPORT_BINARY = "/tmp/export_corners"
EXPORT_SRC    = os.path.join(SCRIPT_DIR, "export_corners.swift")

def build_export_binary():
    """Build the Swift corner-exporter if needed."""
    if os.path.exists(EXPORT_BINARY):
        return True
    src = os.path.join(SCRIPT_DIR, "export_corners_src.swift")
    if not os.path.exists(src):
        print(f"[Error] Swift source not found: {src}")
        print("  Run: python3 BenchmarkTool/review_launcher.py  (it will auto-generate the source)")
        return False
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip()
    cmd = ["swiftc", "-sdk", sdk, "-target", "arm64-apple-macosx14.0", "-O", src, "-o", EXPORT_BINARY]
    print(f"[Build] Compiling corner exporter...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"[Error] Build failed:\n{r.stderr}")
        return False
    print("[Build] Done.")
    return True

def get_vision_corners():
    """Run Swift binary to get Vision-detected corners for all images."""
    cache = "/tmp/vision_corners.json"
    print("[Step 1] Running Vision corner detection on all 72 images...")
    r = subprocess.run([EXPORT_BINARY], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"[Error] Corner export failed:\n{r.stderr}")
        return None
    with open(cache, "w") as f:
        f.write(r.stdout)
    return json.loads(r.stdout)

def load_cached_corners():
    """Load pre-cached Vision corners from /tmp/vision_corners.json."""
    cache = "/tmp/vision_corners.json"
    if os.path.exists(cache):
        with open(cache) as f:
            return json.load(f)
    return None

def main():
    parser = argparse.ArgumentParser(description="ChekiLens Corner Review Launcher")
    parser.add_argument("--all", action="store_true", help="Review all images (not just failures)")
    parser.add_argument("--rmse-threshold", type=float, default=15.0, help="RMSE threshold (px)")
    parser.add_argument("--output", default=OUTPUT_FILE, help="Output corrected annotations path")
    parser.add_argument("--use-cache", action="store_true", help="Use cached /tmp/vision_corners.json")
    args = parser.parse_args()

    # ── Validate env ──
    if not os.path.exists(WEB_UI_PATH):
        print(f"[Error] web_ui.py not found at: {WEB_UI_PATH}")
        sys.exit(1)
    if not os.path.exists(IMAGES_DIR):
        print(f"[Error] Images dir not found: {IMAGES_DIR}")
        sys.exit(1)

    # ── Get corners ──
    if args.use_cache:
        corners_data = load_cached_corners()
        if corners_data is None:
            print("[Warning] Cache miss — running fresh detection...")
            corners_data = get_vision_corners()
    else:
        # Use pre-exported cache from last benchmark run
        corners_data = load_cached_corners()
        if corners_data is None:
            if not os.path.exists(EXPORT_BINARY):
                print(f"[Error] Corner export binary not found: {EXPORT_BINARY}")
                print("  Please run the benchmark first, or build manually:")
                print("  swiftc -sdk $(xcrun --sdk macosx --show-sdk-path) -target arm64-apple-macosx14.0 -O \\")
                print("    BenchmarkTool/export_corners_src.swift -o /tmp/export_corners")
                sys.exit(1)
            corners_data = get_vision_corners()

    if not corners_data:
        print("[Error] No corner data available.")
        sys.exit(1)

    # ── Filter images ──
    if args.all:
        review_items = corners_data
        print(f"[Step 2] Loading ALL {len(review_items)} images for review...")
    else:
        review_items = [item for item in corners_data if item.get("rmse", 0) > args.rmse_threshold]
        print(f"[Step 2] Found {len(review_items)} images with RMSE > {args.rmse_threshold:.0f}px to review...")
        for item in review_items:
            print(f"         ⚠️  {item['filename']}  RMSE={item.get('rmse', 0):.1f}px  ({item.get('method', '?')})")

    if not review_items:
        print("✅ All images are within the RMSE threshold! Nothing to review.")
        sys.exit(0)

    print(f"\n[Step 3] Launching Web UI... ({len(review_items)} images to review)")
    print(f"         Drag the green corner dots to correct the crop boundaries.")
    print(f"         When done, click 'Save & Crop All' in the browser.")

    # ── Add py-gif to path and launch web_ui ──
    sys.path.insert(0, WEB_UI_DIR)
    from web_ui import start_web_review

    # web_ui expects: [{"filename": ..., "path": ..., "points": [[x,y]x4], "method": ...}]
    web_items = []
    for item in review_items:
        web_items.append({
            "filename": item["filename"],
            "path":     item["path"],
            "points":   item["points"],   # [[x,y], [x,y], [x,y], [x,y]] in pixel coords
            "method":   f"{item.get('method','?')} (RMSE={item.get('rmse',0):.1f}px)"
        })

    final_data = start_web_review(web_items)

    # ── Save corrected corners ──
    print(f"\n[Step 4] Saving corrected corners to: {args.output}")
    os.makedirs(os.path.dirname(args.output) if os.path.dirname(args.output) else ".", exist_ok=True)

    # Merge: start with existing manual_corrections if present, then overwrite adjusted ones
    existing = {}
    if os.path.exists(args.output):
        with open(args.output) as f:
            for line in f:
                line = line.strip()
                if line:
                    rec = json.loads(line)
                    existing[rec["filename"]] = rec

    for item in final_data:
        existing[item["filename"]] = {
            "filename": item["filename"],
            "path":     item["path"],
            "points":   item["points"],
            "method":   item["method"],
            "manually_adjusted": True
        }

    with open(args.output, "w") as f:
        for rec in existing.values():
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print(f"✅ Saved {len(final_data)} corrected images to {args.output}")
    print(f"   Total in manual_corrections.jsonl: {len(existing)}")
    print()
    print("📌 Next step: feed these corrected corners back into the benchmark to measure improvement.")
    print("   Run:  python3 BenchmarkTool/review_launcher.py --use-cache")

if __name__ == "__main__":
    main()
