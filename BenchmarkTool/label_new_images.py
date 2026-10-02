import os
import sys
import json
import subprocess
from PIL import Image
import threading
from http.server import HTTPServer, SimpleHTTPRequestHandler
import webbrowser
import urllib.parse

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
IMAGES_DIR   = os.path.join(PROJECT_ROOT, "TestData", "images")
ANNOT_FILE   = os.path.join(PROJECT_ROOT, "TestData", "cheki_annotations.jsonl")

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>ChekiLens - Label New Images (Loupe Pro)</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body { background-color: #111827; color: white; user-select: none; margin: 0; overflow: hidden;}
        #overlay-canvas { cursor: crosshair; touch-action: none; }
        .thumbnail { cursor: pointer; border: 2px solid transparent; }
        .thumbnail:hover { border-color: #9ca3af; }
        .thumbnail.active { border-color: #3b82f6; background-color: #1f2937; }
        ::-webkit-scrollbar { width: 8px; }
        ::-webkit-scrollbar-track { background: #1f2937; }
        ::-webkit-scrollbar-thumb { background: #4b5563; border-radius: 4px; }
        .workspace-bg {
            background-color: #1f2937;
            background-image: linear-gradient(45deg, #111827 25%, transparent 25%, transparent 75%, #111827 75%, #111827), 
                              linear-gradient(45deg, #111827 25%, transparent 25%, transparent 75%, #111827 75%, #111827);
            background-size: 20px 20px;
            background-position: 0 0, 10px 10px;
        }
    </style>
</head>
<body class="flex h-screen text-sm font-sans">
    <div class="w-72 bg-gray-900 border-r border-gray-700 flex flex-col shadow-xl z-20">
        <div class="p-4 bg-gray-800 font-bold text-center border-b border-gray-700">New Images (<span id="counter"></span>)</div>
        <div id="gallery" class="flex-1 overflow-y-auto p-3 grid grid-cols-2 gap-2 content-start"></div>
        <div class="p-4 bg-gray-800 border-t border-gray-700 flex flex-col gap-2">
            <button id="btn-submit" class="w-full bg-blue-600 hover:bg-blue-500 text-white font-bold py-3 rounded shadow-lg transition">Save & Exit</button>
        </div>
    </div>
    
    <div class="flex-1 flex flex-col relative bg-gray-800 h-screen">
        <div class="p-4 bg-gray-900 text-gray-300 flex justify-between items-center z-10 shadow border-b border-gray-700">
            <div class="flex flex-col">
                <span id="filename" class="font-mono font-bold text-white text-lg"></span>
                <span id="method" class="text-xs text-green-400 mt-1"></span>
            </div>
            <div class="text-xs text-gray-400">Drag points to see Magnifying Glass</div>
        </div>
        
        <div id="viewport" class="flex-1 flex items-center justify-center p-4 relative overflow-hidden">
            <div id="workspace" class="relative workspace-bg shadow-2xl rounded-lg overflow-hidden">
                <!-- Static background image -->
                <img id="bg-img" class="absolute pointer-events-none" style="object-fit: contain;">
                <!-- Overlay canvas for points, polygons, and Loupe -->
                <canvas id="overlay-canvas" class="absolute top-0 left-0"></canvas>
            </div>
        </div>
    </div>

    <script>
        const items = DATA_PLACEHOLDER;
        let currentIndex = items.length > 0 ? 0 : -1;
        
        const gallery = document.getElementById('gallery');
        const viewport = document.getElementById('viewport');
        const workspace = document.getElementById('workspace');
        const bgImg = document.getElementById('bg-img');
        const canvas = document.getElementById('overlay-canvas');
        const ctx = canvas.getContext('2d');
        
        let imgObj = null;
        let scale = 1.0;
        
        // Logical padding around the image
        let padX = 0;
        let padY = 0;
        
        let draggingIdx = -1;
        let needsRedraw = false;
        
        function init() {
            document.getElementById('counter').innerText = items.length;
            items.forEach((item, idx) => {
                const div = document.createElement('div');
                div.className = 'thumbnail p-1 rounded bg-gray-800 relative';
                div.innerHTML = `
                    <img src="/image?path=${encodeURIComponent(item.path)}" class="w-full h-24 object-cover pointer-events-none rounded-sm">
                    <div class="text-xs text-center mt-1 truncate text-gray-400 font-mono">${item.filename}</div>
                `;
                div.onclick = () => selectItem(idx);
                gallery.appendChild(div);
            });
            
            document.getElementById('btn-submit').onclick = () => {
                fetch('/save', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(items)
                }).then(() => {
                    document.body.innerHTML = '<div class="flex flex-col items-center justify-center h-screen bg-gray-900 text-green-500 font-bold"><div class="text-4xl mb-4">✅ Saved Successfully!</div><div class="text-gray-400">You can safely close this browser tab.</div></div>';
                });
            };
            
            requestAnimationFrame(renderLoop);
            if (currentIndex !== -1) selectItem(0);
        }
        
        function selectItem(idx) {
            currentIndex = idx;
            Array.from(gallery.children).forEach((c, i) => {
                c.classList.toggle('active', i === idx);
            });
            document.getElementById('filename').innerText = items[idx].filename;
            document.getElementById('method').innerText = items[idx].method;
            
            imgObj = new Image();
            imgObj.src = `/image?path=${encodeURIComponent(items[idx].path)}`;
            bgImg.src = imgObj.src;
            
            imgObj.onload = () => {
                // Keep padding reasonable (e.g. 50% of image width/height) 
                // so the image itself occupies a good chunk of the screen.
                padX = imgObj.width * 0.4;
                padY = imgObj.height * 0.4;
                resizeAndDraw();
            };
        }
        
        function resizeAndDraw() {
            if(!imgObj) return;
            
            const vw = viewport.clientWidth;
            const vh = viewport.clientHeight;
            
            const logicalW = imgObj.width + (padX * 2);
            const logicalH = imgObj.height + (padY * 2);
            
            // Fit the workspace exactly into the viewport
            scale = Math.min(vw / logicalW, vh / logicalH) * 0.98;
            
            const renderW = logicalW * scale;
            const renderH = logicalH * scale;
            
            workspace.style.width = `${renderW}px`;
            workspace.style.height = `${renderH}px`;
            
            bgImg.style.width = `${imgObj.width * scale}px`;
            bgImg.style.height = `${imgObj.height * scale}px`;
            bgImg.style.left = `${padX * scale}px`;
            bgImg.style.top = `${padY * scale}px`;
            
            canvas.width = renderW;
            canvas.height = renderH;
            
            requestRedraw();
        }
        
        function requestRedraw() {
            needsRedraw = true;
        }
        
        function renderLoop() {
            if(needsRedraw && imgObj) {
                draw();
                needsRedraw = false;
            }
            requestAnimationFrame(renderLoop);
        }
        
        function draw() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            
            const pts = items[currentIndex].points; 
            const cx = pts.map(p => (p[0] + padX) * scale);
            const cy = pts.map(p => (p[1] + padY) * scale);
            
            // Draw dimming overlay using 'evenodd' fill
            ctx.fillStyle = 'rgba(0,0,0,0.6)';
            ctx.beginPath();
            ctx.rect(0, 0, canvas.width, canvas.height);
            ctx.moveTo(cx[0], cy[0]);
            for(let i=1; i<4; i++) ctx.lineTo(cx[i], cy[i]);
            ctx.closePath();
            ctx.fill('evenodd');
            
            // Draw polygon outline
            ctx.beginPath();
            ctx.moveTo(cx[0], cy[0]);
            for(let i=1; i<4; i++) ctx.lineTo(cx[i], cy[i]);
            ctx.closePath();
            ctx.lineWidth = 2.5;
            ctx.strokeStyle = '#22c55e';
            ctx.stroke();
            
            // Draw Handles
            for(let i=0; i<4; i++) {
                ctx.beginPath();
                ctx.arc(cx[i], cy[i], draggingIdx === i ? 8 : 6, 0, Math.PI*2);
                ctx.fillStyle = (i === draggingIdx) ? '#ef4444' : '#22c55e';
                ctx.fill();
                ctx.lineWidth = 1.5;
                ctx.strokeStyle = '#ffffff';
                ctx.stroke();
                // inner dot
                ctx.beginPath();
                ctx.arc(cx[i], cy[i], 1, 0, Math.PI*2);
                ctx.fillStyle = '#ffffff';
                ctx.fill();
            }
            
            // --- LOUPE (Magnifying Glass) ---
            if(draggingIdx !== -1) {
                const px = cx[draggingIdx];
                const py = cy[draggingIdx];
                
                const loupeRadius = 70;
                const loupeZoom = 3.0; // 3x zoom
                
                // Position loupe away from cursor
                let lx = px + 100;
                let ly = py - 100;
                if(lx + loupeRadius > canvas.width) lx = px - 100;
                if(ly - loupeRadius < 0) ly = py + 100;
                
                ctx.save();
                // Draw loupe background
                ctx.beginPath();
                ctx.arc(lx, ly, loupeRadius, 0, Math.PI*2);
                ctx.fillStyle = '#1f2937';
                ctx.fill();
                ctx.clip(); // Clip further drawing to the circle
                
                // Source rect on original unscaled image
                const origX = pts[draggingIdx][0];
                const origY = pts[draggingIdx][1];
                const sw = (loupeRadius * 2) / loupeZoom / scale;
                const sh = (loupeRadius * 2) / loupeZoom / scale;
                const sx = origX - (sw / 2);
                const sy = origY - (sh / 2);
                
                // Draw zoomed region from the original image
                try {
                    ctx.drawImage(imgObj, sx, sy, sw, sh, lx - loupeRadius, ly - loupeRadius, loupeRadius * 2, loupeRadius * 2);
                } catch(e) { } // Ignore if totally out of bounds
                
                // Draw crosshair
                ctx.beginPath();
                ctx.moveTo(lx - 15, ly);
                ctx.lineTo(lx + 15, ly);
                ctx.moveTo(lx, ly - 15);
                ctx.lineTo(lx, ly + 15);
                ctx.strokeStyle = '#ef4444';
                ctx.lineWidth = 2;
                ctx.stroke();
                
                ctx.restore();
                
                // Draw outer ring
                ctx.beginPath();
                ctx.arc(lx, ly, loupeRadius, 0, Math.PI*2);
                ctx.lineWidth = 3;
                ctx.strokeStyle = '#3b82f6';
                ctx.stroke();
                ctx.lineWidth = 1;
                ctx.strokeStyle = '#fff';
                ctx.stroke();
            }
        }
        
        function getMousePos(e) {
            const rect = canvas.getBoundingClientRect();
            return {
                x: e.clientX - rect.left,
                y: e.clientY - rect.top
            };
        }
        
        canvas.addEventListener('mousedown', (e) => {
            if(!imgObj) return;
            const pos = getMousePos(e);
            const pts = items[currentIndex].points;
            
            let minDist = 40; 
            draggingIdx = -1;
            
            for(let i=0; i<4; i++) {
                const hx = (pts[i][0] + padX) * scale;
                const hy = (pts[i][1] + padY) * scale;
                const dist = Math.hypot(pos.x - hx, pos.y - hy);
                if(dist < minDist) {
                    minDist = dist;
                    draggingIdx = i;
                }
            }
            if(draggingIdx !== -1) requestRedraw();
        });
        
        window.addEventListener('mousemove', (e) => {
            if(draggingIdx !== -1 && imgObj) {
                const pos = getMousePos(e);
                let nx = (pos.x / scale) - padX;
                let ny = (pos.y / scale) - padY;
                items[currentIndex].points[draggingIdx] = [nx, ny];
                requestRedraw();
            }
        });
        
        window.addEventListener('mouseup', () => {
            if(draggingIdx !== -1) {
                draggingIdx = -1;
                requestRedraw();
            }
        });
        
        window.addEventListener('resize', resizeAndDraw);
        window.onload = init;
    </script>
</body>
</html>
"""

def auto_detect_corners(path, width, height):
    try:
        r = subprocess.run(["/tmp/detect_corners_single", path], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            res = json.loads(r.stdout)
            if "points" in res:
                return res["points"], f"Auto: {res.get('method', 'Unknown')}"
    except Exception as e:
        print(f"Auto-detect failed for {path}: {e}")
    
    pad_x, pad_y = width * 0.1, height * 0.1
    return [
        [pad_x, pad_y], [width - pad_x, pad_y],
        [width - pad_x, height - pad_y], [pad_x, height - pad_y]
    ], "Manual Box"

def main():
    if not os.path.exists(IMAGES_DIR):
        print(f"Error: {IMAGES_DIR} not found.")
        return

    # Compile the swift binary if not exist
    if not os.path.exists("/tmp/detect_corners_single"):
        print("編譯自動判斷模組中...")
        swift_code = """
import Foundation
import CoreImage
import Vision
@main struct App {
    static func main() async {
        let args = CommandLine.arguments
        if args.count < 2 { return }
        let manager = VisionManager()
        guard let cgImg = try? await manager.loadAndPreprocess(url: URL(fileURLWithPath: args[1])) else { return }
        do {
            let res = try await manager.detectQuad(in: cgImg, imageSize: CGSize(width: cgImg.width, height: cgImg.height))
            let pts = res.corners.map { [$0.x, $0.y] }
            let data = try JSONSerialization.data(withJSONObject: ["method": res.method.rawValue, "points": pts])
            print(String(data: data, encoding: .utf8)!)
        } catch { print("{\\"error\\": \\"failed\\"}") }
    }
}
"""
        with open("/tmp/detect_corners_single.swift", "w") as f:
            f.write(swift_code)
        
        # Compile it (silently)
        subprocess.run(
            ["swiftc", "-sdk", subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip(),
             "-target", "arm64-apple-macosx14.0", "-O",
             os.path.join(PROJECT_ROOT, "ChekiLens/Sources/Models/ChekiItem.swift"),
             os.path.join(PROJECT_ROOT, "ChekiLens/Sources/Services/VisionManager.swift"),
             os.path.join(PROJECT_ROOT, "ChekiLens/Sources/Services/VisionManager+PerspectiveCorrect.swift"),
             os.path.join(PROJECT_ROOT, "ChekiLens/Sources/Services/VisionManager+Layer2Hough.swift"),
             os.path.join(PROJECT_ROOT, "ChekiLens/Sources/Services/VisionManager+Layer3WhiteMask.swift"),
             "/tmp/detect_corners_single.swift", "-o", "/tmp/detect_corners_single"],
            capture_output=True
        )

    existing_files = set()
    if os.path.exists(ANNOT_FILE):
        with open(ANNOT_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line:
                    existing_files.add(json.loads(line)["filename"])

    new_images = [f for f in sorted(os.listdir(IMAGES_DIR)) if f.lower().endswith(('.jpg', '.jpeg', '.png')) and f not in existing_files]

    if not new_images:
        print("✅ 所有圖片都已經標註過了！沒有新的圖片需要標註。")
        return

    print(f"🔍 發現 {len(new_images)} 張新圖片！正在使用現有演算法預先判斷四角...")

    web_items = []
    for filename in new_images:
        path = os.path.join(IMAGES_DIR, filename)
        try:
            with Image.open(path) as img:
                w, h = img.width, img.height
        except:
            continue
        
        pts, method = auto_detect_corners(path, w, h)
        
        web_items.append({
            "filename": filename,
            "path": path,
            "width": w,
            "height": h,
            "points": pts,
            "method": method
        })

    html_content = HTML_TEMPLATE.replace("DATA_PLACEHOLDER", json.dumps(web_items))

    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                self.wfile.write(html_content.encode('utf-8'))
            elif self.path.startswith('/image?path='):
                img_path = urllib.parse.unquote(self.path.split('=')[1])
                try:
                    with open(img_path, 'rb') as f:
                        self.send_response(200)
                        self.send_header('Content-type', 'image/jpeg')
                        self.end_headers()
                        self.wfile.write(f.read())
                except:
                    self.send_response(404)
                    self.end_headers()
            else:
                self.send_response(404)
                self.end_headers()
                
        def do_POST(self):
            if self.path == '/save':
                content_len = int(self.headers.get('Content-Length', 0))
                post_body = self.rfile.read(content_len)
                data = json.loads(post_body)
                
                with open(ANNOT_FILE, 'a') as f:
                    for item in data:
                        rec = {
                            "filename": item["filename"],
                            "points": item["points"],
                            "width": item["width"],
                            "height": item["height"]
                        }
                        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                
                self.send_response(200)
                self.end_headers()
                
                threading.Thread(target=lambda: self.server.shutdown()).start()

    server = HTTPServer(('127.0.0.1', 8080), Handler)
    print("\n🚀 啟動超級 WebUI 伺服器 (包含放大鏡 Loupe 功能)...")
    print("👉 請開啟瀏覽器前往: http://localhost:8080")
    webbrowser.open('http://localhost:8080')
    server.serve_forever()
    print("✅ 已關閉伺服器。標註完成！")

if __name__ == "__main__":
    main()
