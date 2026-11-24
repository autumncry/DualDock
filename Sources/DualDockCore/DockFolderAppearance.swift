import Foundation

public enum DockFolderStyle: String, Codable, CaseIterable, Sendable {
    case silver, classic, flat, skeuomorphic, glass
}

/// sRGB components stored independently of the background's opacity.
public struct DockFolderColor: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = unitInterval(red, fallback: 0)
        self.green = unitInterval(green, fallback: 0)
        self.blue = unitInterval(blue, fallback: 0)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(red: fields.decode(Double.self, forKey: .red),
                      green: fields.decode(Double.self, forKey: .green),
                      blue: fields.decode(Double.self, forKey: .blue))
    }
}

public struct DockFolderAppearance: Codable, Equatable, Sendable {
    public var style: DockFolderStyle
    /// A nil color uses the artwork's own palette.
    public var backgroundColor: DockFolderColor?
    public var backgroundOpacity: Double

    public init(style: DockFolderStyle = .silver, backgroundColor: DockFolderColor? = nil,
                backgroundOpacity: Double = 1) {
        self.style = style
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = unitInterval(backgroundOpacity, fallback: 1)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(style: (try? fields.decode(DockFolderStyle.self, forKey: .style)) ?? .silver,
                  backgroundColor: try? fields.decode(DockFolderColor.self, forKey: .backgroundColor),
                  backgroundOpacity: (try? fields.decode(Double.self, forKey: .backgroundOpacity)) ?? 1)
    }

    mutating func normalize() {
        backgroundOpacity = unitInterval(backgroundOpacity, fallback: 1)
    }
}

private func unitInterval(_ value: Double, fallback: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : fallback
}
