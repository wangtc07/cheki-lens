import os, sys, json, threading, webbrowser, urllib.parse
from PIL import Image
from http.server import HTTPServer, SimpleHTTPRequestHandler

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
IMAGES_DIR   = os.path.join(PROJECT_ROOT, "TestData", "images")
ANNOT_FILE   = os.path.join(PROJECT_ROOT, "TestData", "cheki_annotations.jsonl")

# Reuse the HTML template from label_new_images
with open(os.path.join(SCRIPT_DIR, "label_new_images.py"), "r") as f:
    content = f.read()
HTML_TEMPLATE = content.split('HTML_TEMPLATE = """')[1].split('"""')[0]

def main():
    if len(sys.argv) < 2:
        print("用法: python3 BenchmarkTool/edit_existing.py <檔案名稱.JPG>")
        return
        
    target_filename = sys.argv[1]
    
    # Read existing
    all_records = []
    target_record = None
    if os.path.exists(ANNOT_FILE):
        with open(ANNOT_FILE, 'r') as f:
            for line in f:
                if line.strip():
                    rec = json.loads(line)
                    all_records.append(rec)
                    if rec["filename"] == target_filename:
                        target_record = rec
                        
    if not target_record:
        print(f"錯誤: 在 JSONL 裡找不到 {target_filename}")
        return
        
    path = os.path.join(IMAGES_DIR, target_filename)
    if not os.path.exists(path):
        print(f"錯誤: 圖片檔案不存在 {path}")
        return
        
    web_items = [{
        "filename": target_record["filename"],
        "path": path,
        "width": target_record["width"],
        "height": target_record["height"],
        "points": target_record["points"],
        "method": "Editing Existing"
    }]
    
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
                data = json.loads(post_body)[0]
                
                # Update record in memory
                for i, rec in enumerate(all_records):
                    if rec["filename"] == data["filename"]:
                        all_records[i] = data
                        break
                        
                # Rewrite whole file
                with open(ANNOT_FILE, 'w') as f:
                    for rec in all_records:
                        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                
                self.send_response(200)
                self.end_headers()
                threading.Thread(target=lambda: self.server.shutdown()).start()

    server = HTTPServer(('127.0.0.1', 8080), Handler)
    print(f"🚀 啟動編輯伺服器，準備修改 {target_filename} ...")
    webbrowser.open('http://localhost:8080')
    server.serve_forever()
    print("✅ 已關閉伺服器。修改完成！")

if __name__ == "__main__":
    main()
