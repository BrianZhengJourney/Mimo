import CoreGraphics

// Geometry primitives for the companion runtime.
//
// Coordinates are AppKit's: y grows upward, origin at the bottom-left of the
// main display. Shimeji is y-down (Java), so every borrowed constant that has a
// vertical sign is flipped here — gravity pulls toward -y, a floor is the
// surface a companion rests on top of, and a ceiling is above it.
//
// Positions are continuous (CGFloat), not integer pixels. That is a deliberate
// departure from Shimeji, whose `isOn` is exact integer equality on one axis
// (`getY() == location.y`). Equality cannot survive fractional scaling or
// HiDPI, and it forced Shimeji into a -80..0 landing probe to stop fast falls
// from tunnelling through surfaces. With continuous coordinates, resting on a
// surface is a tolerance test and landing is a segment-crossing test, so the
// probe is unnecessary. See docs/companion/01-shimeji-research.md §1.5.

enum CompanionDisplaySize {
    static let minimumPercent: CGFloat = 60
    static let maximumPercent: CGFloat = 140
    static let defaultPercent: CGFloat = 100
    static let nativeBaseHeight: CGFloat = 240

    static func clampedPercent(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultPercent }
        return min(maximumPercent, max(minimumPercent, value))
    }

    static func nativeHeight(percent: CGFloat) -> CGFloat {
        nativeBaseHeight * clampedPercent(percent) / 100
    }
}

enum SurfaceKind {
    /// Supports a companion from below. Anchor rests at `position`.
    case floor
    /// Vertical surface a companion can cling to or bounce off.
    case wall
    /// Overhead surface a companion can hang from.
    case ceiling
}

/// Identifies where a surface came from, so a companion can tell that the
/// ground it is standing on has moved or disappeared.
///
/// P0 only ever produces work-area cases. Window cases exist now so that P4 can
/// add window terrain by appending to `SurfaceSet.surfaces` without touching
/// physics or behavior — see docs/companion/03-runtime-architecture.md §4.5.
enum SurfaceID: Hashable {
    case workAreaBottom(displayID: UInt32)
    case workAreaTop(displayID: UInt32)
    case workAreaLeft(displayID: UInt32)
    case workAreaRight(displayID: UInt32)
    case windowTop(windowID: UInt32)
    case windowBottom(windowID: UInt32)
    case windowLeft(windowID: UInt32)
    case windowRight(windowID: UInt32)
}

/// An axis-aligned line segment a companion can rest on, cling to, or hang from.
///
/// `position` is the constant axis: y for floor/ceiling, x for wall.
/// `span` covers the other axis.
struct Surface {
    let id: SurfaceID
    let kind: SurfaceKind
    let position: CGFloat
    let span: ClosedRange<CGFloat>

    var isVertical: Bool { kind == .wall }

    /// Whether `anchor` is resting on this surface, within `tolerance`.
    func contains(_ anchor: CGPoint, tolerance: CGFloat = CompanionPhysics.surfaceTolerance) -> Bool {
        if isVertical {
            return abs(anchor.x - position) <= tolerance && span.contains(anchor.y)
        }
        return abs(anchor.y - position) <= tolerance && span.contains(anchor.x)
    }

    /// Whether a straight move from `from` to `to` crosses this surface from the
    /// supported side. This replaces Shimeji's landing probe: a fast fall cannot
    /// tunnel because we test the segment, not the endpoint.
    ///
    /// A floor is only crossed while descending, a ceiling only while ascending;
    /// otherwise a companion launching upward off the ground would immediately
    /// re-land on it.
    func isCrossed(from: CGPoint, to: CGPoint) -> Bool {
        if isVertical {
            guard from.x != to.x else { return false }
            let low = min(from.x, to.x), high = max(from.x, to.x)
            guard low <= position && position <= high else { return false }
            let t = (position - from.x) / (to.x - from.x)
            return span.contains(from.y + t * (to.y - from.y))
        }

        switch kind {
        case .floor where to.y > from.y: return false
        case .ceiling where to.y < from.y: return false
        default: break
        }
        guard from.y != to.y else { return false }
        let low = min(from.y, to.y), high = max(from.y, to.y)
        guard low <= position && position <= high else { return false }
        let t = (position - from.y) / (to.y - from.y)
        return span.contains(from.x + t * (to.x - from.x))
    }
}

/// Every surface in the world this frame.
///
/// Deliberately a flat collection rather than "screen edges, plus a special case
/// for windows". P4 appends window surfaces here and nothing downstream changes.
struct SurfaceSet {
    var surfaces: [Surface]

    init(_ surfaces: [Surface] = []) { self.surfaces = surfaces }

    /// The four edges of one display's work area, as seen from inside it: the
    /// bottom edge is a floor, the top edge is a ceiling, the sides are walls.
    ///
    /// Note the inversion that catches people out — for a *window* it is the
    /// reverse (a window's top edge is a floor you stand on, its underside is a
    /// ceiling). That is why `SurfaceID` names edges rather than roles.
    static func workArea(_ rect: CGRect, displayID: UInt32) -> SurfaceSet {
        SurfaceSet([
            Surface(id: .workAreaBottom(displayID: displayID), kind: .floor,
                    position: rect.minY, span: rect.minX...rect.maxX),
            Surface(id: .workAreaTop(displayID: displayID), kind: .ceiling,
                    position: rect.maxY, span: rect.minX...rect.maxX),
            Surface(id: .workAreaLeft(displayID: displayID), kind: .wall,
                    position: rect.minX, span: rect.minY...rect.maxY),
            Surface(id: .workAreaRight(displayID: displayID), kind: .wall,
                    position: rect.maxX, span: rect.minY...rect.maxY),
        ])
    }

    func surface(with id: SurfaceID) -> Surface? {
        surfaces.first { $0.id == id }
    }

    /// The surface of `kind` that `anchor` is currently resting on, if any.
    func resting(on kind: SurfaceKind, at anchor: CGPoint,
                 tolerance: CGFloat = CompanionPhysics.surfaceTolerance) -> Surface? {
        surfaces.first { $0.kind == kind && $0.contains(anchor, tolerance: tolerance) }
    }

    /// The first surface a straight move from `from` to `to` runs into, and where.
    ///
    /// Ties are broken by distance travelled, so a companion falling into a
    /// corner lands on whichever surface it actually reaches first.
    func firstCrossing(from: CGPoint, to: CGPoint) -> (surface: Surface, point: CGPoint)? {
        var best: (surface: Surface, point: CGPoint, distance: CGFloat)?
        for surface in surfaces where surface.isCrossed(from: from, to: to) {
            let point: CGPoint
            if surface.isVertical {
                let t = (surface.position - from.x) / (to.x - from.x)
                point = CGPoint(x: surface.position, y: from.y + t * (to.y - from.y))
            } else {
                let t = (surface.position - from.y) / (to.y - from.y)
                point = CGPoint(x: from.x + t * (to.x - from.x), y: surface.position)
            }
            let distance = hypot(point.x - from.x, point.y - from.y)
            if best == nil || distance < best!.distance {
                best = (surface, point, distance)
            }
        }
        guard let best else { return nil }
        return (best.surface, best.point)
    }

    /// Resolves a grab released with its anchor already beyond a display edge.
    /// Swept collision cannot see a wall when both the start and end points are
    /// outside it and moving farther away, so release needs this one preflight.
    /// Points inside any display remain untouched and keep their throw velocity.
    func workAreaContact(forOutside point: CGPoint) -> (surface: Surface, point: CGPoint)? {
        struct Edges {
            var bottom: Surface?
            var top: Surface?
            var left: Surface?
            var right: Surface?
        }

        var grouped: [UInt32: Edges] = [:]
        for surface in surfaces {
            switch surface.id {
            case .workAreaBottom(let id): grouped[id, default: Edges()].bottom = surface
            case .workAreaTop(let id): grouped[id, default: Edges()].top = surface
            case .workAreaLeft(let id): grouped[id, default: Edges()].left = surface
            case .workAreaRight(let id): grouped[id, default: Edges()].right = surface
            default: break
            }
        }

        var candidates: [(edges: Edges, rect: CGRect, distance: CGFloat)] = []
        for edges in grouped.values {
            guard let bottom = edges.bottom, let top = edges.top,
                  let left = edges.left, let right = edges.right else { continue }
            let rect = CGRect(x: left.position, y: bottom.position,
                              width: right.position - left.position,
                              height: top.position - bottom.position)
            let insideX = (rect.minX...rect.maxX).contains(point.x)
            let insideY = (rect.minY...rect.maxY).contains(point.y)
            if insideX && insideY { return nil }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            candidates.append((edges, rect, dx * dx + dy * dy))
        }

        guard let nearest = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        let rect = nearest.rect
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)

        if dx > 0 && (dy == 0 || dx <= dy) {
            let surface = point.x < rect.minX ? nearest.edges.left : nearest.edges.right
            return surface.map { ($0, CGPoint(x: $0.position, y: clampedY)) }
        }
        let surface = point.y < rect.minY ? nearest.edges.bottom : nearest.edges.top
        return surface.map { ($0, CGPoint(x: clampedX, y: $0.position)) }
    }
}

/// Brings a companion back when it has left the world.
///
/// This is not hypothetical. The companion layer covers `screen.frame` while
/// the floor sits at `visibleFrame.minY`, so the strip of screen behind the
/// Dock is *below* the floor. Drop or throw a companion into it and the floor
/// can never be reached again: a floor is only crossed while descending
/// *through* its y, and from underneath there is nothing left to descend
/// through. It falls forever, off-screen, unrecoverable.
///
/// Shimeji's answer to losing a mascot is to teleport it above the screen and
/// drop it — self-healing but silent, so an authoring error reads as rain. The
/// recovery here is the same idea with the diagnostic kept.
enum CompanionRecovery {
    /// Slack so a companion resting exactly on a boundary is not "lost".
    static let tolerance: CGFloat = 8

    /// Where to put an anchor that has left every work area, or nil if it is
    /// somewhere legal.
    static func recoveredAnchor(for anchor: CGPoint, workAreas: [CGRect]) -> CGPoint? {
        guard !workAreas.isEmpty else { return nil }
        let isInside = workAreas.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(anchor) }
        if isInside { return nil }

        // Land on the floor of whichever work area is nearest, so a companion
        // thrown off the bottom of one display comes back on that display
        // rather than jumping to the primary one.
        let nearest = workAreas.min { lhs, rhs in
            squaredDistance(from: anchor, to: lhs) < squaredDistance(from: anchor, to: rhs)
        } ?? workAreas[0]
        return CGPoint(x: min(max(anchor.x, nearest.minX + tolerance), nearest.maxX - tolerance),
                       y: nearest.minY)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// Rounds a point to the display's physical pixel grid.
///
/// Physics runs in continuous coordinates so slow drift stays smooth; the
/// renderer snaps to device pixels so sprite art stays crisp. Shimeji got both
/// properties from an integer position plus a sub-pixel carry (`modX`/`modY`);
/// splitting it this way is the same trade made one layer later, and it also
/// works when two displays have different backing scales.
func devicePixelSnapped(_ point: CGPoint, scale: CGFloat) -> CGPoint {
    guard scale > 0 else { return point }
    return CGPoint(x: (point.x * scale).rounded() / scale,
                   y: (point.y * scale).rounded() / scale)
}
