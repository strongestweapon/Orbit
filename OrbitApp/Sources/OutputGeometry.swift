import Foundation
import CoreGraphics

/// The LED packing stays in a 3840×2160 coordinate system at every output size.
enum OutputResolution: String, CaseIterable, Codable, Identifiable {
    case automatic, hd, fullHD, qhd, uhd, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "화면에 맞춤 (자동)"
        case .hd: return "1280 × 720 · HD"
        case .fullHD: return "1920 × 1080 · FHD"
        case .qhd: return "2560 × 1440 · QHD"
        case .uhd: return "3840 × 2160 · 4K"
        case .custom: return "직접 입력"
        }
    }
    func size(availablePixels: CGSize, customWidth: Int) -> CGSize {
        switch self {
        case .automatic: return OutputGeometry.automaticSize(in: availablePixels)
        case .hd: return CGSize(width: 1280, height: 720)
        case .fullHD: return CGSize(width: 1920, height: 1080)
        case .qhd: return CGSize(width: 2560, height: 1440)
        case .uhd: return CGSize(width: 3840, height: 2160)
        case .custom:
            let width = OutputGeometry.normalizedWidth(customWidth)
            return CGSize(width: CGFloat(width), height: CGFloat(width / 16 * 9))
        }
    }
}

enum OutputGeometry {
    static let aspectRatio: CGFloat = 16.0 / 9.0
    static func normalizedWidth(_ width: Int) -> Int {
        min(7680, max(320, width)) / 16 * 16
    }
    static func fittedRect(in bounds: CGRect) -> CGRect {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let height = min(bounds.height, bounds.width / aspectRatio)
        let width = height * aspectRatio
        return CGRect(x: bounds.midX-width/2, y: bounds.midY-height/2, width: width, height: height)
    }
    static func automaticSize(in pixels: CGSize) -> CGSize {
        guard pixels.width.isFinite, pixels.height.isFinite,
              pixels.width >= 16, pixels.height >= 9 else { return .zero }
        let unit = min(480, floor(min(pixels.width/16, pixels.height/9)))
        return CGSize(width: unit*16, height: unit*9)
    }
    static func label(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }
}
