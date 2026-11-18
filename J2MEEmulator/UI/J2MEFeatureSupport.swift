//
// J2MEFeatureSupport.swift
// iOS equivalents of the Android helper classes supplied for porting.
//
// This file intentionally does NOT impose a total item limit.
// Paging is for the visible UI only; item IDs remain unbounded.
//

import UIKit

final class J2MEItemPageController<Item> {
    let pageSize: Int
    private(set) var items: [Item] = []

    init(pageSize: Int = 20) {
        self.pageSize = max(1, pageSize)
    }

    func replace(with items: [Item]) {
        self.items = items
    }

    func append(_ item: Item) {
        items.append(item)
    }

    func append(contentsOf newItems: [Item]) {
        items.append(contentsOf: newItems)
    }

    func clear() {
        items.removeAll(keepingCapacity: false)
    }

    func page(_ page: Int) -> ArraySlice<Item> {
        guard page >= 0 else { return [] }

        let start = page * pageSize
        guard start < items.count else { return [] }

        let end = min(start + pageSize, items.count)
        return items[start..<end]
    }

    var pageCount: Int {
        guard !items.isEmpty else { return 0 }
        return (items.count + pageSize - 1) / pageSize
    }
}

final class J2MEImageCache {
    static let shared = J2MEImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Bounded memory cache, not a bounded item count.
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func image(data: Data, key: String) -> UIImage? {
        if let cached = image(forKey: key) {
            return cached
        }

        guard let image = UIImage(data: data) else {
            return nil
        }

        insert(image, forKey: key)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }
}

final class J2MEKeyboardAvoidance {
    static func install(on view: UIView) -> [NSObjectProtocol] {
        let willChange = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak view] note in
            guard let view,
                  let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }

            let converted = view.convert(frame, from: nil)
            let overlap = max(0, view.bounds.maxY - converted.minY)

            if let scroll = view as? UIScrollView {
                scroll.contentInset.bottom = overlap + 12
                scroll.verticalScrollIndicatorInsets.bottom = overlap + 12
            } else {
                view.layoutMargins.bottom = overlap
            }
        }

        let willHide = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak view] _ in
            guard let view else { return }

            if let scroll = view as? UIScrollView {
                scroll.contentInset.bottom = 12
                scroll.verticalScrollIndicatorInsets.bottom = 12
            } else {
                view.layoutMargins.bottom = 0
            }
        }

        return [willChange, willHide]
    }
}
