import Foundation

enum BrainVisualizationMode: String, CaseIterable, Identifiable {
    case anatomy
    case graph
    case atlas
    case flywire
    case wholeFly

    var id: Self { self }

    var title: String {
        switch self {
        case .anatomy:
            return "Volume"
        case .graph:
            return "Graph"
        case .atlas:
            return "Atlas"
        case .flywire:
            return "Meshes"
        case .wholeFly:
            return "Whole Fly"
        }
    }
}
