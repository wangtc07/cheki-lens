// ChekiBenchmark/Sources/main.swift
// macOS CLI — 72 張實體拍立得照片精度驗證工具
//
// 執行：swift run --package-path BenchmarkTool
// 輸出：
//   ・終端機統計報告（命中率、平均像素誤差）
//   ・TestData/output/ 裁切結果 JPEG

import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision

// ─────────────────────────────────────────────
// MARK: - 從 ChekiLens Sources 複製必要型別（Benchmark 獨立套件）
// ─────────────────────────────────────────────
// NOTE: BenchmarkTool は iOS ターゲットと別の SPM パッケージのため，
//       ChekiLens/Sources から直接 import できない。
//       そのため，必要な型・ロジックをこのファイル内に inline する。

// ─── FilmFormat ───
enum FilmFormat {
    case mini, square, wide, auto
    var aspectRatio: Double {
        switch self { case .mini: return 86.0/54.0; case .square: return 86.0/72.0
        case .wide: return 108.0/86.0; case .auto: return 0 }
    }
    static let outputLongEdge = 3840
}

// ─── DetectionMethodUsed ───
enum DetectionMethodUsed: String { case vision, hough, whiteMask, failed }

// ─── Structs ───
struct DetectionResult {
    var corners: [CGPoint]
    var method: DetectionMethodUsed
    var confidence: Double
}
struct CropResult { var cgImage: CGImage; var detection: DetectionResult }

// ─── Annotation (JSONL) ───
struct Annotation: Decodable {
    let filename: String
    let points: [[Double]]   // [[x1,y1],[x2,y2],[x3,y3],[x4,y4]]
    let width: Int
    let height: Int
}

// ─────────────────────────────────────────────
// MARK: - Geometry
// ─────────────────────────────────────────────
func orderPoints(_ pts: [CGPoint]) -> [CGPoint] {
    guard pts.count == 4 else { return pts }
    let sorted = pts.sorted { $0.x + $0.y < $1.x + $1.y }
    let tl = sorted.first!, br = sorted.last!
    let rem = pts.filter { $0 != tl && $0 != br }
    let tr = rem.min(by: { $0.y - $0.x < $1.y - $1.x })!
    let bl = rem.max(by: { $0.y - $0.x < $1.y - $1.x })!
    return [tl, tr, br, bl]
}

func quadAspectRatio(_ pts: [CGPoint]) -> Double {
    let o = orderPoints(pts)
    let w = hypot(o[1].x - o[0].x, o[1].y - o[0].y)
    let h = hypot(o[3].x - o[0].x, o[3].y - o[0].y)
    let lo = max(w, h), sh = min(w, h)
    return sh > 0 ? Double(lo / sh) : 0
}

func quadArea(_ pts: [CGPoint]) -> Double {
    var a = 0.0
    for i in 0..<pts.count {
        let j = (i+1) % pts.count
        a += Double(pts[i].x * pts[j].y - pts[j].x * pts[i].y)
    }
    return abs(a) / 2
}

func isChekiRatio(_ pts: [CGPoint]) -> Bool {
    let r = quadAspectRatio(pts); return 1.20 <= r && r <= 1.90
}

// ─────────────────────────────────────────────
// MARK: - Image Load
// ─────────────────────────────────────────────
func loadCGImage(url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let ci = CIImage(cgImage: img)
    let ctx = CIContext()
    return ctx.createCGImage(ci, from: ci.extent)
}

// ─────────────────────────────────────────────
// MARK: - Layer 1: Vision
// ─────────────────────────────────────────────
func detectVision(image: CGImage, imgW: Double, imgH: Double) -> DetectionResult? {
    let req = VNDetectRectanglesRequest()
    req.minimumAspectRatio  = 0.10
    req.maximumAspectRatio  = 0.99
    req.minimumSize         = 0.01
    req.maximumObservations = 20
    req.minimumConfidence   = 0.1

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try? handler.perform([req])
    guard let obs = req.results, !obs.isEmpty else { return nil }

    var best: (corners: [CGPoint], area: Double, conf: Double)?
    for o in obs {
        let pts: [CGPoint] = [
            CGPoint(x: o.topLeft.x  * imgW, y: (1-o.topLeft.y)  * imgH),
            CGPoint(x: o.topRight.x * imgW, y: (1-o.topRight.y) * imgH),
            CGPoint(x: o.bottomRight.x * imgW, y: (1-o.bottomRight.y) * imgH),
            CGPoint(x: o.bottomLeft.x  * imgW, y: (1-o.bottomLeft.y)  * imgH),
        ]
        let area = quadArea(pts)
        guard area >= 0.03 * imgW * imgH, isChekiRatio(pts) else { continue }
        if best == nil || area > best!.area {
            best = (pts, area, Double(o.confidence))
        }
    }
    guard let r = best else { return nil }
    return DetectionResult(corners: orderPoints(r.corners), method: .vision, confidence: r.conf)
}

// ─────────────────────────────────────────────
// MARK: - Layer 2: Hough (simplified for benchmark speed)
// ─────────────────────────────────────────────
func extractGrayPixels(image: CGImage, w: Int, h: Int) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w*4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    ctx.draw(image, in: CGRect(x:0,y:0,width:w,height:h))
    return (0..<w*h).map { i in
        let r=Int(px[i*4]), g=Int(px[i*4+1]), b=Int(px[i*4+2])
        return UInt8(clamping: (r*77+g*150+b*29)>>8)
    }
}

func rgbToHSV(_ r:Int,_ g:Int,_ b:Int) -> (s:Int, v:Int) {
    let rf=Double(r)/255, gf=Double(g)/255, bf=Double(b)/255
    let cmax=max(rf,gf,bf), cmin=min(rf,gf,bf), delta=cmax-cmin
    return (cmax>0 ? Int((delta/cmax)*255) : 0, Int(cmax*255))
}

func buildMask(pixels: [UInt8], rgba: [UInt8], w: Int, h: Int, sMax: Int, vMin: Int) -> [UInt8] {
    var m = [UInt8](repeating: 0, count: w*h)
    for i in 0..<w*h {
        let r=Int(rgba[i*4]), g=Int(rgba[i*4+1]), b=Int(rgba[i*4+2])
        let (s,v) = rgbToHSV(r,g,b)
        if s <= sMax && v >= vMin { m[i] = 255 }
    }
    return m
}

func dilate(_ inp: [UInt8], w:Int, h:Int, r:Int) -> [UInt8] {
    var out=[UInt8](repeating:0,count:w*h)
    for y in 0..<h { for x in 0..<w {
        var v=UInt8(0)
        for dy in -r...r { for dx in -r...r {
            let nx=x+dx, ny=y+dy
            guard nx>=0&&nx<w&&ny>=0&&ny<h else{continue}
            v=max(v, inp[ny*w+nx])
        }}; out[y*w+x]=v
    }}; return out
}
func erode(_ inp: [UInt8], w:Int, h:Int, r:Int) -> [UInt8] {
    var out=[UInt8](repeating:255,count:w*h)
    for y in 0..<h { for x in 0..<w {
        var v=UInt8(255)
        for dy in -r...r { for dx in -r...r {
            let nx=x+dx, ny=y+dy
            guard nx>=0&&nx<w&&ny>=0&&ny<h else{continue}
            v=min(v, inp[ny*w+nx])
        }}; out[y*w+x]=v
    }}; return out
}

func sobel(_ inp: [UInt8], w:Int, h:Int, thresh:UInt8=30) -> [UInt8] {
    var out=[UInt8](repeating:0,count:w*h)
    for y in 1..<(h-1) { for x in 1..<(w-1) {
        let gx = Int(inp[(y-1)*w+(x+1)])+2*Int(inp[y*w+(x+1)])+Int(inp[(y+1)*w+(x+1)])
               - Int(inp[(y-1)*w+(x-1)])-2*Int(inp[y*w+(x-1)])-Int(inp[(y+1)*w+(x-1)])
        let gy = Int(inp[(y+1)*w+(x-1)])+2*Int(inp[(y+1)*w+x])+Int(inp[(y+1)*w+(x+1)])
               - Int(inp[(y-1)*w+(x-1)])-2*Int(inp[(y-1)*w+x])-Int(inp[(y-1)*w+(x+1)])
        let mag = UInt8(clamping: Int(sqrt(Double(gx*gx+gy*gy))))
        out[y*w+x] = mag > thresh ? 255 : 0
    }}; return out
}

struct HLine { var rho:Double; var theta:Double }

func houghTransform(_ mask:[UInt8], w:Int, h:Int, thresh:Int) -> [HLine] {
    let diag = Int(sqrt(Double(w*w+h*h)))+1
    let nT = 180, nR = diag*2
    var acc=[Int](repeating:0,count:nR*nT)
    let pi = Double.pi
    var cosT=[Double](repeating:0,count:nT), sinT=[Double](repeating:0,count:nT)
    for t in 0..<nT { cosT[t]=cos(Double(t)*pi/Double(nT)); sinT[t]=sin(Double(t)*pi/Double(nT)) }
    for y in 0..<h { for x in 0..<w {
        guard mask[y*w+x] > 0 else { continue }
        for t in 0..<nT {
            let ri = Int(Double(x)*cosT[t]+Double(y)*sinT[t])+diag
            if ri>=0 && ri<nR { acc[ri*nT+t] += 1 }
        }
    }}
    var res=[HLine]()
    for ri in 0..<nR { for t in 0..<nT {
        if acc[ri*nT+t] >= thresh {
            res.append(HLine(rho: Double(ri-diag), theta: Double(t)*pi/Double(nT)))
        }
    }}; return res
}

func intersection(_ l1:HLine, _ l2:HLine) -> CGPoint? {
    let c1=cos(l1.theta),s1=sin(l1.theta),c2=cos(l2.theta),s2=sin(l2.theta)
    let det=c1*s2-c2*s1; guard abs(det)>1e-6 else { return nil }
    return CGPoint(x: (l1.rho*s2-l2.rho*s1)/det, y: (l2.rho*c1-l1.rho*c2)/det)
}

func dedup(_ lines:[HLine], dist:Double) -> [HLine] {
    var res=[HLine]()
    for l in lines { if res.isEmpty || abs(l.rho-res.last!.rho)>dist { res.append(l) } }
    return res
}

func detectHough(image: CGImage, imgW: Int, imgH: Int) -> DetectionResult? {
    // RGBA ピクセル抽出
    var rgba=[UInt8](repeating:0,count:imgW*imgH*4)
    guard let ctx=CGContext(data:&rgba,width:imgW,height:imgH,bitsPerComponent:8,
                            bytesPerRow:imgW*4,space:CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in:CGRect(x:0,y:0,width:imgW,height:imgH))
    let gray=extractGrayPixels(image:image,w:imgW,h:imgH)

    // Dual Mask
    var bestCorners: [CGPoint]?
    var bestScore = -Double.infinity

    let whiteParams = [(sMax:50,vMin:170),(sMax:70,vMin:150),(sMax:40,vMin:185)]
    var allLines=[HLine]()

    for p in whiteParams {
        var m=buildMask(pixels:gray,rgba:rgba,w:imgW,h:imgH,sMax:p.sMax,vMin:p.vMin)
        m=dilate(m,w:imgW,h:imgH,r:3); m=erode(m,w:imgW,h:imgH,r:3)
        let edges=sobel(m,w:imgW,h:imgH)
        // スケール 4
        let sw=imgW/4, sh=imgH/4
        var small=[UInt8](repeating:0,count:sw*sh)
        for y in 0..<sh { for x in 0..<sw { small[y*sw+x]=edges[(y*4)*imgW+(x*4)] } }
        let ht=houghTransform(small,w:sw,h:sh,thresh:80)
        allLines += ht.map { HLine(rho:$0.rho*4, theta:$0.theta) }
    }
    // Bright mask
    var bright=gray.map { $0 > 60 ? UInt8(255) : 0 }
    bright=dilate(bright,w:imgW,h:imgH,r:10); bright=erode(bright,w:imgW,h:imgH,r:10)
    let bedges=sobel(bright,w:imgW,h:imgH)
    let sw=imgW/4, sh=imgH/4
    var bsmall=[UInt8](repeating:0,count:sw*sh)
    for y in 0..<sh { for x in 0..<sw { bsmall[y*sw+x]=bedges[(y*4)*imgW+(x*4)] } }
    allLines += houghTransform(bsmall,w:sw,h:sh,thresh:80).map { HLine(rho:$0.rho*4, theta:$0.theta) }

    guard !allLines.isEmpty else { return nil }

    let pi = Double.pi
    let hT = 25.0*pi/180.0, vT = 25.0*pi/180.0
    var horiz=[HLine](), vert=[HLine]()
    for l in allLines {
        var t=l.theta; if t > pi { t -= pi }
        if t < hT || t > pi-hT { vert.append(l) }
        else if abs(t-pi/2) < vT { horiz.append(l) }
    }
    guard horiz.count>=2, vert.count>=2 else { return nil }
    horiz=dedup(horiz.sorted{$0.rho<$1.rho}, dist:40)
    vert=dedup(vert.sorted{$0.rho<$1.rho}, dist:40)

    let margin=0.15, iW=Double(imgW), iH=Double(imgH)
    for i in 0..<horiz.count { for j in (i+1)..<horiz.count {
        for k in 0..<vert.count { for l2 in (k+1)..<vert.count {
            guard let tl=intersection(horiz[i],vert[k]),
                  let tr=intersection(horiz[i],vert[l2]),
                  let br=intersection(horiz[j],vert[l2]),
                  let bl=intersection(horiz[j],vert[k]) else { continue }
            let corners=[tl,tr,br,bl]
            let ok=corners.allSatisfy{$0.x >= -margin*iW && $0.x <= iW*(1+margin) && $0.y >= -margin*iH && $0.y <= iH*(1+margin)}
            guard ok else { continue }
            let area=quadArea(corners), minA=0.04*iW*iH, maxA=0.60*iW*iH
            guard area>=minA && area<=maxA else { continue }
            let ratio=quadAspectRatio(corners)
            guard 1.45<=ratio && ratio<=1.75 else { continue }
            let score=area/(1.0+5.0*abs(ratio-86.0/54.0))
            if score>bestScore { bestScore=score; bestCorners=corners }
        }}
    }}

    guard let c=bestCorners else { return nil }
    return DetectionResult(corners:orderPoints(c), method:.hough,
                           confidence:min(1.0,bestScore/(0.30*iW*iH)))
}

// ─────────────────────────────────────────────
// MARK: - Perspective Crop
// ─────────────────────────────────────────────
func perspectiveCrop(image: CGImage, corners: [CGPoint]) -> CGImage? {
    let imgW=CGFloat(image.width), imgH=CGFloat(image.height)
    let o=orderPoints(corners)
    let tl=o[0],tr=o[1],br=o[2],bl=o[3]
    let wTop=hypot(tr.x-tl.x,tr.y-tl.y), hLeft=hypot(bl.x-tl.x,bl.y-tl.y)
    let (fTL,fTR,fBR,fBL): (CGPoint,CGPoint,CGPoint,CGPoint)
    if wTop>hLeft { fTL=bl;fTR=tl;fBR=tr;fBL=br } else { fTL=tl;fTR=tr;fBR=br;fBL=bl }

    func norm(_ p:CGPoint) -> CIVector { CIVector(x:p.x/imgW,y:(imgH-p.y)/imgH) }
    guard let f=CIFilter(name:"CIPerspectiveCorrection") else { return nil }
    f.setValue(CIImage(cgImage:image), forKey:kCIInputImageKey)
    f.setValue(norm(fTL), forKey:"inputTopLeft")
    f.setValue(norm(fTR), forKey:"inputTopRight")
    f.setValue(norm(fBR), forKey:"inputBottomRight")
    f.setValue(norm(fBL), forKey:"inputBottomLeft")
    guard let out=f.outputImage else { return nil }

    // Lanczos resize → 縦長 3840px
    let ratio=86.0/54.0
    let th=3840.0, tw=th/ratio
    guard let ls=CIFilter(name:"CILanczosScaleTransform") else { return nil }
    ls.setValue(out, forKey:kCIInputImageKey)
    let scaleY=th/out.extent.height
    let scaleX=tw/out.extent.width
    ls.setValue(scaleY, forKey:kCIInputScaleKey)
    ls.setValue(scaleX/scaleY, forKey:kCIInputAspectRatioKey)
    guard let resized=ls.outputImage else { return nil }
    let ctx=CIContext()
    return ctx.createCGImage(resized, from:resized.extent)
}

func saveCGImage(_ img:CGImage, to url:URL) {
    guard let dest=CGImageDestinationCreateWithURL(url as CFURL,"public.jpeg" as CFString,1,nil)
    else { return }
    CGImageDestinationAddImage(dest,img,[kCGImageDestinationLossyCompressionQuality:0.88] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

// ─────────────────────────────────────────────
// MARK: - Accuracy Metrics
// ─────────────────────────────────────────────
func cornerRMSE(_ pred: [CGPoint], _ gt: [CGPoint], scale: Double) -> Double {
    // pred と gt を同じスケールに正規化してから比較
    let pairs = zip(pred, gt)
    let sumSq = pairs.reduce(0.0) { acc, pair in
        let dx = Double(pair.0.x) - pair.1.x * scale
        let dy = Double(pair.0.y) - pair.1.y * scale
        return acc + dx*dx + dy*dy
    }
    return sqrt(sumSq / Double(pred.count))
}

// ─────────────────────────────────────────────
// MARK: - Main
// ─────────────────────────────────────────────
let scriptDir = URL(fileURLWithPath: "/Users/tcwang/Documents/ChekiLens/BenchmarkTool/Sources")
let testDataDir = URL(fileURLWithPath: "/Users/tcwang/Documents/ChekiLens/TestData")
let imagesDir    = testDataDir.appendingPathComponent("images")
let annotFile    = testDataDir.appendingPathComponent("cheki_annotations.jsonl")
let outputDir    = testDataDir.appendingPathComponent("output")

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// JSONL 読み込み
let annotLines = (try String(contentsOf: annotFile, encoding: .utf8))
    .components(separatedBy: .newlines).filter { !$0.isEmpty }
let annotations = annotLines.compactMap { line -> Annotation? in
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Annotation.self, from: data)
}

print("═══════════════════════════════════════════════════════")
print("  ChekiLens Vision Pipeline Benchmark — \(annotations.count) images")
print("═══════════════════════════════════════════════════════")
print(String(format: "%-40@ %-10@ %-8@ %-8@", "Filename", "Method", "RMSE(px)", "Status"))
print(String(repeating: "─", count: 72))

var stats = [String: Int]()
var totalRMSE = 0.0
var hitCount = 0        // RMSE ≤ 15px
var successCount = 0    // 任意の方法で検出成功
let hitThreshold = 15.0 // px

let start = Date()

for annot in annotations {
    let imgURL = imagesDir.appendingPathComponent(annot.filename)
    guard let img = loadCGImage(url: imgURL) else {
        print(String(format: "%-40s %-10s", annot.filename, "LOAD_ERR"))
        continue
    }
    let imgW = img.width, imgH = img.height

    // Ground truth corners（JSONL は width=800/height=533 正規化済み）
    let scaleX = Double(imgW) / Double(annot.width)
    let scaleY = Double(imgH) / Double(annot.height)
    let gtCorners: [CGPoint] = annot.points.map {
        CGPoint(x: $0[0] * scaleX, y: $0[1] * scaleY)
    }
    let gtOrdered = orderPoints(gtCorners)

    // Detection（Layer1 → Layer2 Fallback）
    var result: DetectionResult?
    if let r = detectHough(image: img, imgW: imgW, imgH: imgH) {
        result = r
    } else if let r = detectVision(image: img, imgW: Double(imgW), imgH: Double(imgH)) {
        result = r
    }

    let methodStr = result?.method.rawValue ?? "failed"
    stats[methodStr, default: 0] += 1

    if let det = result {
        successCount += 1
        let predOrdered = orderPoints(det.corners)
        let rmse = cornerRMSE(predOrdered, gtOrdered, scale: 1.0)
        totalRMSE += rmse
        let hit = rmse <= hitThreshold
        if hit { hitCount += 1 }
        let status = hit ? "✅" : "⚠️"
        let fn = annot.filename.padding(toLength: 40, withPad: " ", startingAt: 0)
        let meth = methodStr.padding(toLength: 10, withPad: " ", startingAt: 0)
        let rmseStr = String(format: "%7.1f", rmse)
        print("\(fn) \(meth) \(rmseStr) \(status)")

        // 裁切結果を保存（RMSE に関わらず全件）
        if let cropped = perspectiveCrop(image: img, corners: det.corners) {
            let outURL = outputDir.appendingPathComponent(
                annot.filename.replacingOccurrences(of: ".JPG", with: "_crop.jpg"))
            saveCGImage(cropped, to: outURL)
        }
    } else {
        print(String(format: "%-40s %-10s %7s ❌", annot.filename, "failed", "-"))
    }
}

let elapsed = Date().timeIntervalSince(start)

print(String(repeating: "═", count: 72))
print("\n📊 結果統計 Results Summary")
print("─────────────────────────────────────────")
let total = Double(annotations.count)
let hitRate = Double(hitCount) / total * 100
let successRate = Double(successCount) / total * 100
let avgRMSE = successCount > 0 ? totalRMSE / Double(successCount) : 0

print(String(format: "  Total images    : %d", annotations.count))
print(String(format: "  Detected        : %d / %d (%.1f%%)", successCount, annotations.count, successRate))
print(String(format: "  Hit (≤%.0fpx)  : %d / %d (%.1f%%)", hitThreshold, hitCount, annotations.count, hitRate))
print(String(format: "  Avg RMSE        : %.2f px", avgRMSE))
print(String(format: "  Elapsed         : %.1f sec", elapsed))
print("")
print("  Detection method breakdown:")
for (method, count) in stats.sorted(by: { $0.value > $1.value }) {
    print(String(format: "    %-15s : %d", method, count))
}
print("")
print("  Output saved to: TestData/output/")
print("═══════════════════════════════════════════════════════")
