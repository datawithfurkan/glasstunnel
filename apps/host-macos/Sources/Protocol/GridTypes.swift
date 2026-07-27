import Foundation

public struct GridCellPosition: Codable, Sendable, Hashable {
    public var row: Int
    public var col: Int
    public var rowSpan: Int
    public var colSpan: Int

    public init(row: Int, col: Int, rowSpan: Int = 1, colSpan: Int = 1) {
        self.row = row
        self.col = col
        self.rowSpan = rowSpan
        self.colSpan = colSpan
    }
}

public struct GridCell: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(position.row)-\(position.col)" }
    public var position: GridCellPosition
    public var agentId: AgentID
    public var windowTitle: String
    public var applicationBundleId: String
    public var adapterKind: AdapterKind
    public var videoEnabled: Bool

    public init(
        position: GridCellPosition,
        agentId: AgentID,
        windowTitle: String = "",
        applicationBundleId: String = "",
        adapterKind: AdapterKind = .mirror,
        videoEnabled: Bool = true
    ) {
        self.position = position
        self.agentId = agentId
        self.windowTitle = windowTitle
        self.applicationBundleId = applicationBundleId
        self.adapterKind = adapterKind
        self.videoEnabled = videoEnabled
    }
}

public struct GridLayout: Codable, Sendable, Hashable {
    public var shape: GridShape
    public var cells: [GridCell]

    public init(shape: GridShape = .twoByTwo, cells: [GridCell] = []) {
        self.shape = shape
        self.cells = cells
    }

    /// An empty layout with placeholders at every position for the given shape.
    public static func empty(shape: GridShape) -> GridLayout {
        var cells: [GridCell] = []
        for r in 0..<shape.rows {
            for c in 0..<shape.cols {
                cells.append(GridCell(
                    position: GridCellPosition(row: r, col: c),
                    agentId: "",
                    adapterKind: .unspecified
                ))
            }
        }
        return GridLayout(shape: shape, cells: cells)
    }

    public func cell(at position: GridCellPosition) -> GridCell? {
        cells.first(where: { $0.position.row == position.row && $0.position.col == position.col })
    }

    public mutating func replace(cell: GridCell) {
        if let idx = cells.firstIndex(where: { $0.id == cell.id }) {
            cells[idx] = cell
        } else {
            cells.append(cell)
        }
    }
}
