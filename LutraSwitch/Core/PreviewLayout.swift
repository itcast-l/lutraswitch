import Foundation

enum PreviewStyle {
    case switcher
    case dock

    var panelPadding: CGFloat { 14 }
    var cardSpacing: CGFloat { 10 }
    var cardPadding: CGFloat { 8 }
    var metadataSpacing: CGFloat { 8 }
    var chromeHeight: CGFloat { 26 }
    var cardWidth: CGFloat { self == .switcher ? 252 : 210 }
    var thumbnailHeight: CGFloat { self == .switcher ? 140 : 110 }
    var metadataHeight: CGFloat { self == .switcher ? 34 : 24 }
    var cardInsetsHeight: CGFloat { cardPadding * 2 + metadataSpacing + metadataHeight }
}

struct PreviewLayout: Equatable {
    static let thumbnailLimit = 5
    static let iconHeight: CGFloat = 66
    static let iconSpacing: CGFloat = 8
    static let pageControlsHeight: CGFloat = 26

    let size: CGSize
    let contentWidth: CGFloat
    let thumbnailColumns: Int
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let thumbnailRowsHeight: CGFloat
    let iconColumns: Int
    let iconWidth: CGFloat
    let iconRowsHeight: CGFloat
    let iconsPerPage: Int
    let pageCount: Int

    private let iconCount: Int

    init(style: PreviewStyle, windowCount: Int, available: CGSize) {
        let thumbnails = min(max(1, windowCount), Self.thumbnailLimit)
        let icons = max(0, windowCount - thumbnails)
        let spacing = style.cardSpacing
        let padding = style.panelPadding * 2
        let width = min(available.width, CGFloat(thumbnails) * style.cardWidth + CGFloat(thumbnails - 1) * spacing + padding)
        let content = max(1, width - padding)
        let baseHeight = padding + style.chromeHeight + spacing
        let iconColumns = max(1, Int((content + Self.iconSpacing) / (108 + Self.iconSpacing)))
        let iconRows = Self.rows(count: icons, columns: iconColumns)
        let reservedIcons = icons == 0 ? 0 : spacing + Self.iconHeight
            + (iconRows > 1 ? spacing + Self.pageControlsHeight : 0)

        // Wrap the first five only on a narrow display with room for a second row.
        let preferredColumns = min(thumbnails, max(1, Int((content + spacing) / (132 + spacing))))
        let preferredRows = Self.rows(count: thumbnails, columns: preferredColumns)
        let minimumHeight = baseHeight + reservedIcons
            + CGFloat(preferredRows) * (style.cardInsetsHeight + 48) + CGFloat(preferredRows - 1) * spacing
        let columns = minimumHeight <= available.height ? preferredColumns : thumbnails
        let thumbnailRows = Self.rows(count: thumbnails, columns: columns)
        let cardWidth = (content - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let thumbnailGap = CGFloat(thumbnailRows - 1) * spacing
        let maxCardHeight = (available.height - baseHeight - reservedIcons - thumbnailGap) / CGFloat(thumbnailRows)
        let imageHeight = max(1, floor(min(style.thumbnailHeight * min(1, cardWidth / style.cardWidth),
                                           maxCardHeight - style.cardInsetsHeight)))
        let thumbnailArea = CGFloat(thumbnailRows) * (imageHeight + style.cardInsetsHeight) + thumbnailGap

        let iconBudget = available.height - baseHeight - thumbnailArea - spacing
        let iconRowStep = Self.iconHeight + Self.iconSpacing
        let fullRows = max(1, Int((iconBudget + Self.iconSpacing) / iconRowStep))
        let paging = iconRows > fullRows
        let pageBudget = iconBudget - (paging ? Self.pageControlsHeight + spacing : 0)
        let rowsPerPage = min(iconRows, max(1, Int((pageBudget + Self.iconSpacing) / iconRowStep)))
        let capacity = max(1, rowsPerPage * iconColumns)
        let pages = max(1, Self.rows(count: icons, columns: capacity))
        let iconArea = rowsPerPage == 0 ? 0 : CGFloat(rowsPerPage) * iconRowStep - Self.iconSpacing

        size = CGSize(width: width, height: baseHeight + thumbnailArea
                      + (icons > 0 ? spacing + iconArea : 0)
                      + (pages > 1 ? spacing + Self.pageControlsHeight : 0))
        contentWidth = content
        thumbnailColumns = columns
        thumbnailWidth = cardWidth
        thumbnailHeight = imageHeight
        thumbnailRowsHeight = thumbnailArea
        self.iconColumns = iconColumns
        iconWidth = (content - CGFloat(iconColumns - 1) * Self.iconSpacing) / CGFloat(iconColumns)
        iconRowsHeight = iconArea
        iconsPerPage = capacity
        pageCount = pages
        iconCount = icons
    }

    func iconRange(page: Int) -> Range<Int> {
        let start = min(max(0, page), pageCount - 1) * iconsPerPage
        return start..<min(iconCount, start + iconsPerPage)
    }

    func page(containingWindowAt index: Int) -> Int? {
        let icon = index - Self.thumbnailLimit
        guard (0..<iconCount).contains(icon) else { return nil }
        return icon / iconsPerPage
    }

    private static func rows(count: Int, columns: Int) -> Int {
        (count + columns - 1) / columns
    }
}
