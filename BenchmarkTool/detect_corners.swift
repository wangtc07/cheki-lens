import Foundation
import CoreImage
import Vision

// Dummy implementations so we can compile quickly without the whole project
@main
struct App {
    static func main() async {
        let args = CommandLine.arguments
        if args.count < 2 { return }
        let path = args[1]
        let url = URL(fileURLWithPath: path)
        
        let manager = VisionManager()
        guard let cgImg = try? await manager.loadAndPreprocess(url: url) else { return }
        let size = CGSize(width: cgImg.width, height: cgImg.height)
        
        do {
            let res = try await manager.detectQuad(in: cgImg, imageSize: size)
            let pts = res.corners.map { [$0.x, $0.y] }
            let data = try JSONSerialization.data(withJSONObject: ["method": res.method.rawValue, "points": pts])
            print(String(data: data, encoding: .utf8)!)
        } catch {
            print("{\"error\": \"failed\"}")
        }
    }
}
