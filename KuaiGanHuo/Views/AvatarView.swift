import SwiftUI
import PhotosUI
import UIKit

// MARK: - 头像模型

/// 头像来源：内置几何头像（代码程序化绘制，零第三方素材、零版权风险）或用户自定义图片
enum AvatarKind: Equatable, Hashable {
    case builtin(Int)
    case custom(String)

    /// 持久化编码（UserDefaults 只存字符串）
    var encoded: String {
        switch self {
        case .builtin(let i): return "b:\(i)"
        case .custom(let f): return "c:\(f)"
        }
    }

    init?(encoded: String) {
        if encoded.hasPrefix("b:"), let i = Int(encoded.dropFirst(2)) {
            self = .builtin(i)
            return
        }
        if encoded.hasPrefix("c:") {
            self = .custom(String(encoded.dropFirst(2)))
            return
        }
        return nil
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

/// 内置头像：几何图案 + 双色渐变。全部由 SwiftUI Shape 绘制，不依赖任何图片素材。
struct BuiltInAvatar: Identifiable {
    let id: Int
    var pattern: Pattern
    var top: Color
    var bottom: Color
    var ink: Color

    enum Pattern {
        case circle, ring, triangle, bars, diagonal, quarter
        case dots, doubleRing, half, cross, stripes, diamond
    }
}

/// 12 款内置头像（配色取自 iOS 系统色板，图案为通用几何形，不构成任何作品的独创性表达）
let builtInAvatars: [BuiltInAvatar] = [
    BuiltInAvatar(id: 1,  pattern: .circle,     top: Color(hex: 0x0A84FF), bottom: Color(hex: 0x409CFF), ink: .white),
    BuiltInAvatar(id: 2,  pattern: .ring,       top: Color(hex: 0x5E5CE6), bottom: Color(hex: 0x7D7DF0), ink: .white),
    BuiltInAvatar(id: 3,  pattern: .triangle,   top: Color(hex: 0xFF9F0A), bottom: Color(hex: 0xFFB340), ink: .white),
    BuiltInAvatar(id: 4,  pattern: .bars,       top: Color(hex: 0x30D158), bottom: Color(hex: 0x5BD97A), ink: .white),
    BuiltInAvatar(id: 5,  pattern: .diagonal,   top: Color(hex: 0xBF5AF2), bottom: Color(hex: 0xD07BF7), ink: .white),
    BuiltInAvatar(id: 6,  pattern: .quarter,    top: Color(hex: 0x40C8E0), bottom: Color(hex: 0x64D6EA), ink: .white),
    BuiltInAvatar(id: 7,  pattern: .dots,       top: Color(hex: 0xFF375F), bottom: Color(hex: 0xFF6480), ink: .white),
    BuiltInAvatar(id: 8,  pattern: .doubleRing, top: Color(hex: 0x2C2C2E), bottom: Color(hex: 0x48484A), ink: .white),
    BuiltInAvatar(id: 9,  pattern: .half,       top: Color(hex: 0xFF453A), bottom: Color(hex: 0xFF6961), ink: .white),
    BuiltInAvatar(id: 10, pattern: .cross,      top: Color(hex: 0xFFD60A), bottom: Color(hex: 0xFFE04D), ink: Color(hex: 0x3A2E00)),
    BuiltInAvatar(id: 11, pattern: .stripes,    top: Color(hex: 0xAC8E68), bottom: Color(hex: 0xC4A986), ink: .white),
    BuiltInAvatar(id: 12, pattern: .diamond,    top: Color(hex: 0x64D2FF), bottom: Color(hex: 0x8FDCFF), ink: Color(hex: 0x0A3A52))
]

/// 角色的默认头像：上司=蓝圆、父母=橙三角、伴侣=粉点，其余按序分配
func defaultBuiltInIndex(for roleID: String) -> Int {
    let table: [String: Int] = ["boss": 1, "parent": 3, "partner": 7]
    if let fixed = table[roleID] { return fixed }
    let seed = abs(roleID.hashValue)
    return (seed % builtInAvatars.count) + 1
}

// MARK: - 绘制

/// 头像画面：渐变底 + 几何图案，按容器比例自适应
struct AvatarArtwork: View {
    let avatar: BuiltInAvatar

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: [avatar.top, avatar.bottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                patternView(size: s)
            }
        }
    }

    @ViewBuilder
    private func patternView(size: CGFloat) -> some View {
        let ink = avatar.ink
        switch avatar.pattern {
        case .circle:
            Circle().fill(ink).frame(width: size * 0.46, height: size * 0.46)
        case .ring:
            Circle().stroke(ink, lineWidth: size * 0.09).frame(width: size * 0.5, height: size * 0.5)
        case .triangle:
            TriangleShape().fill(ink).frame(width: size * 0.52, height: size * 0.46)
        case .bars:
            VStack(spacing: size * 0.07) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: size * 0.05)
                        .fill(ink)
                        .frame(width: size * 0.52, height: size * 0.08)
                }
            }
        case .diagonal:
            DiagonalShape().fill(ink.opacity(0.9))
        case .quarter:
            QuarterShape().fill(ink)
        case .dots:
            DotGridShape().fill(ink).frame(width: size * 0.56, height: size * 0.56)
        case .doubleRing:
            ZStack {
                Circle().stroke(ink, lineWidth: size * 0.07).frame(width: size * 0.54, height: size * 0.54)
                Circle().fill(ink).frame(width: size * 0.18, height: size * 0.18)
            }
        case .half:
            HalfShape().fill(ink)
        case .cross:
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.05).fill(ink)
                    .frame(width: size * 0.5, height: size * 0.13)
                RoundedRectangle(cornerRadius: size * 0.05).fill(ink)
                    .frame(width: size * 0.13, height: size * 0.5)
            }
        case .stripes:
            StripesShape().fill(ink)
        case .diamond:
            RoundedRectangle(cornerRadius: size * 0.08)
                .fill(ink)
                .frame(width: size * 0.38, height: size * 0.38)
                .rotationEffect(.degrees(45))
        }
    }
}

/// 头像视图：内置头像按几何绘制，自定义头像读本地图片；统一圆形裁切
struct AvatarView: View {
    let kind: AvatarKind
    var size: CGFloat = 40

    var body: some View {
        Group {
            switch kind {
            case .builtin(let i):
                let index = (i >= 1 && i <= builtInAvatars.count) ? i - 1 : 0
                AvatarArtwork(avatar: builtInAvatars[index])
            case .custom(let filename):
                if let img = AvatarStore.load(filename) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    // 图片丢失（如清缓存后）→ 回落到内置头像，不留空白
                    AvatarArtwork(avatar: builtInAvatars[0])
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - 自定义头像存取

/// 自定义头像保存在 Application Support/Avatars，文件名存进 AppState
enum AvatarStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存压缩后的图片（上限 512px，避免原图塞爆存储），返回文件名
    @discardableResult
    static func save(_ data: Data) -> String? {
        guard let raw = UIImage(data: data) else { return nil }
        let scaled = raw.resized(maxSide: 512)
        guard let out = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        let filename = "ava_" + UUID().uuidString + ".jpg"
        let url = directory.appendingPathComponent(filename)
        do {
            try out.write(to: url)
            return filename
        } catch {
            return nil
        }
    }

    static func load(_ filename: String) -> UIImage? {
        guard !filename.isEmpty else { return nil }
        let url = directory.appendingPathComponent(filename)
        return UIImage(contentsOfFile: url.path)
    }

    static func delete(_ filename: String) {
        guard !filename.isEmpty else { return }
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 头像选择界面

/// 头像选择器：内置 12 款 + 从相册选一张
struct AvatarPickerView: View {
    let title: String
    @Binding var selection: AvatarKind
    @State private var pickerItem: PhotosPickerItem?
    @State private var customFilename: String?
    @State private var pickError: String?

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 当前头像大图预览
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        AvatarView(kind: selection, size: 96)
                        Text(selection.isCustom ? "你的照片" : "内置头像")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 8)

                Text("内置头像")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(builtInAvatars) { ava in
                        let kind = AvatarKind.builtin(ava.id)
                        Button {
                            selection = kind
                        } label: {
                            AvatarView(kind: kind, size: 64)
                                .overlay(
                                    Circle()
                                        .stroke(selection == kind ? Color.accentColor : Color.clear, lineWidth: 3)
                                        .padding(-3)
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    if selection == kind {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                            .background(Circle().fill(Color(.systemBackground)))
                                            .font(.system(size: 18))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("内置头像 \(ava.id)")
                    }
                }

                Text("用我的照片")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 22))
                            Text("从相册选")
                                .font(.caption2)
                        }
                        .frame(width: 64, height: 64)
                        .background(Color(.systemGray6))
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    if let f = customFilename {
                        Button {
                            selection = .custom(f)
                        } label: {
                            AvatarView(kind: .custom(f), size: 64)
                                .overlay(
                                    Circle()
                                        .stroke(selection == .custom(f) ? Color.accentColor : Color.clear, lineWidth: 3)
                                        .padding(-3)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }

                if let err = pickError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("内置头像由 App 自己画的几何图形，不涉及任何第三方素材；选照片的话图片只存在你手机里，不上传。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        pickError = "这张图读不出来，换一张试试"
                        return
                    }
                    if let name = AvatarStore.save(data) {
                        customFilename = name
                        selection = .custom(name)
                        pickError = nil
                    } else {
                        pickError = "保存失败，换一张试试"
                    }
                } catch {
                    pickError = "读取失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 自定义几何 Shape

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct DiagonalShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct QuarterShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.minX, y: rect.minY),
            radius: rect.width * 0.72,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

private struct HalfShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY),
            radius: rect.width * 0.5,
            startAngle: .degrees(180),
            endAngle: .degrees(360),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

private struct DotGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        let n = 3
        let r = rect.width / CGFloat(n * 2 + 1)
        var p = Path()
        for row in 0..<n {
            for col in 0..<n {
                let cx = r + CGFloat(col * 2 + 1) * r
                let cy = r + CGFloat(row * 2 + 1) * r
                p.addEllipse(in: CGRect(x: cx - r * 0.62, y: cy - r * 0.62, width: r * 1.24, height: r * 1.24))
            }
        }
        return p
    }
}

private struct StripesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let n = 4
        let w = rect.width / CGFloat(n * 2 - 1)
        var p = Path()
        for i in 0..<n {
            p.addRect(CGRect(x: CGFloat(i * 2) * w, y: rect.minY, width: w, height: rect.height))
        }
        return p
    }
}

// MARK: - 辅助

private extension UIImage {
    /// 等比缩放到长边不超过 maxSide
    func resized(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

extension Color {
    /// 十六进制色值（如 0x0A84FF）
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
