import Foundation

// 剖析 CLI 的 UI 桩:GameCore 的 label 辅助引用了展示层类型,
// 枚举/规则计算不依赖 label 内容,空数据即可(标签回退到默认文案)。
enum BoardPresentationCatalog {
    struct Location { let id: String; let name: String }
    static let standard = Board(locations: [])
    struct Board { let locations: [Location] }
}

enum RealMatchViewModel {
    static func cardTitle(_ definitionID: String) -> String { definitionID }
}
