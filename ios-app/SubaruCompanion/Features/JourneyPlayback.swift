import Foundation

struct PlaybackSample: Identifiable {
    var point: JourneyPoint
    var segment: Int
    var id: Double { point.time }
}

enum JourneyPlayback {
    static func index(at time: Double, points: [JourneyPoint]) -> Int? {
        guard !points.isEmpty, time.isFinite else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if points[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }
    static func speed(at time: Double, points: [JourneyPoint], stops: [DriveStop]) -> Double? {
        if stops.contains(where: { time >= $0.start && time <= $0.end }) { return 0 }
        guard let index = index(at: time, points: points) else { return nil }
        let point = points[index]
        guard time >= point.time, time - point.time <= 2, point.speed >= 0, point.speed.isFinite else { return nil }
        return point.speed
    }
    /// Preserve segment boundaries while bounding chart work on long journeys.
    static func chart(_ points: [JourneyPoint], budget: Int = 240) -> [PlaybackSample] {
        guard !points.isEmpty else { return [] }
        let step = max(1, Int(ceil(Double(points.count) / Double(max(1,budget)))))
        var result: [PlaybackSample] = [], segment = 0
        for i in points.indices {
            let p = points[i]
            let starts = i == 0 || p.time - points[i-1].time > 10 || points[i-1].speed < 0
            if starts { segment += 1 }
            guard p.speed.isFinite, p.speed >= 0 else { continue }
            let ends = i == points.count-1 || points[i+1].time - p.time > 10 || points[i+1].speed < 0
            if starts || ends || i.isMultiple(of: step) { result.append(PlaybackSample(point: p,segment: segment)) }
        }
        return result
    }
}
