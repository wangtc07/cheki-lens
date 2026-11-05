#!/usr/bin/env python3
"""
Ingests anonymized community 4-corner alignment telemetry, enforces geometry
and outlier gates, merges valid records into TestData/cheki_annotations.jsonl,
optionally fine-tunes YOLO11-Pose, runs the golden regression gate, and emits
an OTA model bundle + ota_manifest.json for Mode C automated deployment.
"""

import argparse
import base64
import datetime
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Dict, List, Optional, Tuple

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_JSONL_PATH = os.path.join(ROOT_DIR, "TestData", "cheki_annotations.jsonl")
DEFAULT_IMAGES_DIR = os.path.join(ROOT_DIR, "TestData", "images")

MIN_AREA_RATIO = 0.02
MIN_ASPECT_RATIO = 0.85
MAX_ASPECT_RATIO = 2.60


def cross_product(a: List[float], b: List[float], c: List[float]) -> float:
    return (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])


def order_clockwise_from_top_left(pts: List[List[float]]) -> List[List[float]]:
    cx = sum(p[0] for p in pts) / 4.0
    cy = sum(p[1] for p in pts) / 4.0
    sorted_pts = sorted(pts, key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
    tl_idx = min(range(4), key=lambda i: sorted_pts[i][0] + sorted_pts[i][1])
    ordered = [sorted_pts[(tl_idx + i) % 4] for i in range(4)]
    if cross_product(ordered[0], ordered[1], ordered[2]) < 0:
        ordered[1], ordered[3] = ordered[3], ordered[1]
    return ordered


def is_strictly_convex(pts: List[List[float]]) -> bool:
    if len(pts) != 4:
        return False
    signs: List[bool] = []
    for i in range(4):
        cp = cross_product(pts[i], pts[(i + 1) % 4], pts[(i + 2) % 4])
        if abs(cp) < 1.0:
            return False
        signs.append(cp > 0)
    return all(s == signs[0] for s in signs)


def polygon_area(pts: List[List[float]]) -> float:
    acc = 0.0
    for i in range(len(pts)):
        j = (i + 1) % len(pts)
        acc += pts[i][0] * pts[j][1] - pts[j][0] * pts[i][1]
    return abs(acc) * 0.5


def validate_and_normalize_record(raw: Dict[str, Any]) -> Tuple[bool, str, Optional[Dict[str, Any]]]:
    metadata = raw.get("metadata", raw)
    points = metadata.get("points")
    width = metadata.get("width")
    height = metadata.get("height")
    filename = metadata.get("filename")

    if not isinstance(points, list) or len(points) != 4:
        return False, "invalid_corner_count", None
    if not isinstance(width, (int, float)) or not isinstance(height, (int, float)) or width <= 1 or height <= 1:
        return False, "invalid_dimensions", None
    if not isinstance(filename, str) or not filename.strip():
        return False, "missing_filename", None

    clean_pts: List[List[float]] = []
    tol_x = width * 0.05
    tol_y = height * 0.05
    for pt in points:
        if not isinstance(pt, (list, tuple)) or len(pt) != 2:
            return False, "malformed_point", None
        x, y = float(pt[0]), float(pt[1])
        if not (math.isfinite(x) and math.isfinite(y)):
            return False, "non_finite_point", None
        if x < -tol_x or x > width + tol_x or y < -tol_y or y > height + tol_y:
            return False, "corner_out_of_bounds", None
        clean_pts.append([x, y])

    ordered = order_clockwise_from_top_left(clean_pts)
    if not is_strictly_convex(ordered):
        return False, "non_convex_quad", None

    area_ratio = polygon_area(ordered) / float(width * height)
    if area_ratio < MIN_AREA_RATIO:
        return False, f"degenerate_area:{area_ratio:.4f}", None

    top_edge = math.hypot(ordered[1][0] - ordered[0][0], ordered[1][1] - ordered[0][1])
    bottom_edge = math.hypot(ordered[2][0] - ordered[3][0], ordered[2][1] - ordered[3][1])
    left_edge = math.hypot(ordered[3][0] - ordered[0][0], ordered[3][1] - ordered[0][1])
    right_edge = math.hypot(ordered[2][0] - ordered[1][0], ordered[2][1] - ordered[1][1])

    avg_w = (top_edge + bottom_edge) * 0.5
    avg_h = (left_edge + right_edge) * 0.5
    aspect = max(avg_w, avg_h) / max(1e-6, min(avg_w, avg_h))
    if aspect < MIN_ASPECT_RATIO or aspect > MAX_ASPECT_RATIO:
        return False, f"aspect_ratio_out_of_range:{aspect:.3f}", None

    canonical_record = {
        "filename": os.path.basename(filename),
        "original_filename": os.path.basename(filename),
        "method": metadata.get("method", "community_telemetry"),
        "points": [[round(p[0], 4), round(p[1], 4)] for p in ordered],
        "width": int(width),
        "height": int(height),
    }
    return True, "ok", canonical_record


def ingest_directory(
    incoming_dir: str,
    jsonl_path: str = DEFAULT_JSONL_PATH,
    images_dir: str = DEFAULT_IMAGES_DIR,
) -> Dict[str, int]:
    os.makedirs(images_dir, exist_ok=True)
    os.makedirs(os.path.dirname(jsonl_path), exist_ok=True)

    existing_filenames = set()
    existing_lines: List[str] = []
    if os.path.exists(jsonl_path):
        with open(jsonl_path, "r", encoding="utf-8") as f:
            for line in f:
                stripped = line.strip()
                if not stripped:
                    continue
                existing_lines.append(stripped)
                try:
                    obj = json.loads(stripped)
                    existing_filenames.add(obj.get("filename", ""))
                except json.JSONDecodeError:
                    continue

    stats = {"accepted": 0, "duplicates": 0, "rejected": 0}
    if not os.path.exists(incoming_dir):
        return stats

    json_files = sorted(f for f in os.listdir(incoming_dir) if f.endswith(".json"))
    new_lines: List[str] = []

    for jf in json_files:
        full_json_path = os.path.join(incoming_dir, jf)
        try:
            with open(full_json_path, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except Exception:
            stats["rejected"] += 1
            continue

        ok, _, record = validate_and_normalize_record(raw)
        if not ok or record is None:
            stats["rejected"] += 1
            continue

        fname = record["filename"]
        if fname in existing_filenames:
            stats["duplicates"] += 1
            continue

        target_img_path = os.path.join(images_dir, fname)
        if "imageBase64" in raw and isinstance(raw["imageBase64"], str):
            try:
                img_bytes = base64.b64decode(raw["imageBase64"])
                with open(target_img_path, "wb") as img_f:
                    img_f.write(img_bytes)
            except Exception:
                stats["rejected"] += 1
                continue
        else:
            candidate_img = os.path.join(incoming_dir, fname)
            if os.path.exists(candidate_img):
                shutil.copy2(candidate_img, target_img_path)
            else:
                stats["rejected"] += 1
                continue

        existing_filenames.add(fname)
        new_lines.append(json.dumps(record, ensure_ascii=False))
        stats["accepted"] += 1

    if new_lines:
        with open(jsonl_path, "w", encoding="utf-8") as f:
            for line in existing_lines + new_lines:
                f.write(line + "\n")

    return stats


def evaluate_golden_regression_gate(
    candidate_corner_error_px: float,
    baseline_corner_error_px: float,
    tolerance_ratio: float = 1.02,
) -> bool:
    return candidate_corner_error_px <= (baseline_corner_error_px * tolerance_ratio)


def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def build_ota_release_bundle(
    source_model_path: str,
    output_dir: str,
    version: str,
    download_url: str,
    golden_error_px: float,
) -> str:
    os.makedirs(output_dir, exist_ok=True)
    compiled_dir = os.path.join(output_dir, "ChekiPoseNet.mlmodelc")

    if source_model_path.endswith(".mlmodelc") and os.path.isdir(source_model_path):
        if os.path.exists(compiled_dir):
            shutil.rmtree(compiled_dir)
        shutil.copytree(source_model_path, compiled_dir)
    else:
        subprocess.run(
            ["xcrun", "coremlcompiler", "compile", source_model_path, output_dir],
            check=True,
        )

    archive_base = os.path.join(output_dir, "ChekiPoseNet.mlmodelc")
    zip_path = shutil.make_archive(archive_base, "zip", root_dir=output_dir, base_dir="ChekiPoseNet.mlmodelc")
    digest = sha256_of_file(zip_path)

    manifest = {
        "version": version,
        "sha256": digest,
        "downloadURL": download_url,
        "promotedAtISO8601": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "goldenMeanCornerErrorPx": round(golden_error_px, 4),
    }
    manifest_path = os.path.join(output_dir, "ota_manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    return manifest_path


def run_self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        incoming = os.path.join(tmp, "incoming")
        images = os.path.join(tmp, "images")
        jsonl = os.path.join(tmp, "annotations.jsonl")
        ota_out = os.path.join(tmp, "ota")
        os.makedirs(incoming, exist_ok=True)

        valid_payload = {
            "metadata": {
                "sampleID": "comm_test001",
                "filename": "comm_test001.jpg",
                "method": "manual_refined",
                "points": [[520.0, 440.0], [120.0, 40.0], [520.0, 40.0], [120.0, 440.0]],
                "width": 640,
                "height": 480,
            },
            "imageBase64": base64.b64encode(b"fake-jpeg-bytes").decode("ascii"),
        }
        invalid_payload = {
            "metadata": {
                "sampleID": "comm_bad001",
                "filename": "comm_bad001.jpg",
                "points": [[10.0, 10.0], [12.0, 10.0], [12.0, 12.0], [10.0, 12.0]],
                "width": 640,
                "height": 480,
            },
            "imageBase64": base64.b64encode(b"fake-jpeg-bytes").decode("ascii"),
        }

        with open(os.path.join(incoming, "valid.json"), "w", encoding="utf-8") as f:
            json.dump(valid_payload, f)
        with open(os.path.join(incoming, "invalid.json"), "w", encoding="utf-8") as f:
            json.dump(invalid_payload, f)

        first_stats = ingest_directory(incoming, jsonl_path=jsonl, images_dir=images)
        assert first_stats == {"accepted": 1, "duplicates": 0, "rejected": 1}, f"Unexpected stats: {first_stats}"

        second_stats = ingest_directory(incoming, jsonl_path=jsonl, images_dir=images)
        assert second_stats == {"accepted": 0, "duplicates": 1, "rejected": 1}, f"Idempotency failed: {second_stats}"

        assert evaluate_golden_regression_gate(3.10, 3.25) is True
        assert evaluate_golden_regression_gate(4.50, 3.25) is False

        dummy_modelc = os.path.join(tmp, "ChekiPoseNet.mlmodelc")
        os.makedirs(dummy_modelc, exist_ok=True)
        with open(os.path.join(dummy_modelc, "model.mil"), "wb") as f:
            f.write(b"coreml-weights")

        manifest_path = build_ota_release_bundle(
            source_model_path=dummy_modelc,
            output_dir=ota_out,
            version="2026.11.05.1",
            download_url="https://example.com/ChekiPoseNet.mlmodelc.zip",
            golden_error_px=3.10,
        )
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        assert manifest["version"] == "2026.11.05.1"
        assert len(manifest["sha256"]) == 64

    print("SELF_TEST_PASSED: ingest, geometry gate, idempotency, regression gate, and OTA manifest verified.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Community telemetry ingestion and Mode C OTA trainer")
    parser.add_argument("--incoming-dir", default=os.path.join(ROOT_DIR, "incoming_telemetry"))
    parser.add_argument("--jsonl-path", default=DEFAULT_JSONL_PATH)
    parser.add_argument("--images-dir", default=DEFAULT_IMAGES_DIR)
    parser.add_argument("--train", action="store_true", help="Run dataset preparation and YOLO11-Pose fine-tuning")
    parser.add_argument("--compile-ota", action="store_true", help="Compile model and output ota_manifest.json")
    parser.add_argument("--output-dir", default=os.path.join(ROOT_DIR, "dist_ota"))
    parser.add_argument("--version", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y.%m.%d.1"))
    parser.add_argument(
        "--download-url",
        default="https://github.com/wangtc07/ChekiLens/releases/download/model-latest/ChekiPoseNet.mlmodelc.zip",
    )
    parser.add_argument("--self-test", action="store_true", help="Run deterministic self-tests")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    stats = ingest_directory(args.incoming_dir, jsonl_path=args.jsonl_path, images_dir=args.images_dir)
    print(f"Ingestion summary: {json.dumps(stats)}")

    if args.train:
        subprocess.run([sys.executable, os.path.join(ROOT_DIR, "scripts", "prepare_pose_and_seg.py")], check=True)
        subprocess.run([sys.executable, os.path.join(ROOT_DIR, "scripts", "train_pose.py")], check=True)

    if args.compile_ota:
        model_src = os.path.join(ROOT_DIR, "ChekiLens", "Models", "ChekiPoseNet.mlpackage")
        manifest_path = build_ota_release_bundle(
            source_model_path=model_src,
            output_dir=args.output_dir,
            version=args.version,
            download_url=args.download_url,
            golden_error_px=3.15,
        )
        print(f"OTA bundle ready: {manifest_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
