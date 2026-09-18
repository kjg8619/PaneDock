// PaneDock 앱 아이콘 생성기 (제작용 에셋)
//
// 시안 이미지를 붙이지 않고, 시안의 **pane 형태**를 코드로 그려 `.icns`를 만든다.
// 실행:  swiftc -O Sources/PaneDockApp/PaneDockSymbol.swift assets/make-icon.swift -o /tmp/mkicon
//        /tmp/mkicon assets/PaneDock.iconset && iconutil -c icns assets/PaneDock.iconset -o assets/PaneDock.icns

import AppKit
import Foundation

@main
struct IconGenerator {
    static func main() {
        let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/PaneDock.iconset"
        let sizes: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]

        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        for entry in sizes {
            let image = PaneDockSymbol.appIconImage(size: CGFloat(entry.pixels))
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("render failed: \(entry.name)\n".utf8))
                exit(1)
            }
            let path = "\(outputDirectory)/\(entry.name).png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) (\(entry.pixels)px)")
            } catch {
                FileHandle.standardError.write(Data("write failed: \(path)\n".utf8))
                exit(1)
            }
        }
    }
}
