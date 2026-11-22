// SPDX-License-Identifier: MIT

import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing and van Wijk): rectangles whose
/// areas are proportional to `values`, as close to square as it can.
public enum Treemap {
    /// One rectangle per value, in the order given. Zero and negative values get an empty rect.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var out = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        // Largest first works best; remember original positions.
        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        var free = rect
        var row: [Int] = []

        func area(_ i: Int) -> Double { values[i] * scale }
        func worst(_ r: [Int], side: Double) -> Double {
            let s = r.reduce(0) { $0 + area($1) }
            guard s > 0, side > 0 else { return .infinity }
            let mx = r.map(area).max() ?? 0, mn = r.map(area).min() ?? 0
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }
        func lay(_ r: [Int]) {
            let s = r.reduce(0) { $0 + area($1) }
            let wide = free.width >= free.height
            let side = Double(wide ? free.height : free.width)
            let thick = s / side
            var offset = 0.0
            for i in r {
                let len = area(i) / thick
                out[i] = wide
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thick, height: len)
                    : CGRect(x: free.minX + offset, y: free.minY, width: len, height: thick)
                offset += len
            }
            free = wide
                ? CGRect(x: free.minX + thick, y: free.minY, width: max(free.width - thick, 0), height: free.height)
                : CGRect(x: free.minX, y: free.minY + thick, width: free.width, height: max(free.height - thick, 0))
        }

        for i in order {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [i], side: side) <= worst(row, side: side) {
                row.append(i)
            } else {
                lay(row)
                row = [i]
            }
        }
        if !row.isEmpty { lay(row) }
        return out
    }
}
