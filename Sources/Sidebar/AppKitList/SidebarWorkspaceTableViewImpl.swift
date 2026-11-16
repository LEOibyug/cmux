import AppKit
import CmuxFoundation
import SwiftUI

/// Contiguous row range for one workspace group inside ``SidebarWorkspaceTableViewImpl``.
struct SidebarGroupContainerRegion: Equatable {
    let groupId: UUID
    let startRow: Int
    let endRow: Int
    let tintHex: String?
}

/// Event-owning NSTableView for the default workspace sidebar.
@MainActor
final class SidebarWorkspaceTableViewImpl: NSTableView {
    weak var workspaceController: SidebarWorkspaceTableController?
    /// AppKit can retain this table as a native drag source after SwiftUI
    /// dismantles its representable. Keep the controller alive until the
    /// terminal source callback arrives.
    var activeWorkspaceDragController: SidebarWorkspaceTableController?
    private let emptyAreaWindowDragController = SidebarEmptyAreaWindowDragController()
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var lastPointerWindowLocation: NSPoint?

    private let groupContainersLayer = CALayer()
    private var groupContainerLayers: [CAShapeLayer] = []
    private var groupContainerRegions: [SidebarGroupContainerRegion] = []
    private var groupContainerIsDark = true
    private var groupContainerAccentColor = CmuxAccentColor()
    private var groupContainerIncreaseContrast = false

    func updateGroupContainers(
        regions: [SidebarGroupContainerRegion],
        colorSchemeIsDark: Bool,
        accentColor: CmuxAccentColor,
        increaseContrast: Bool
    ) {
        groupContainerRegions = regions
        groupContainerIsDark = colorSchemeIsDark
        groupContainerAccentColor = accentColor
        groupContainerIncreaseContrast = increaseContrast
        layoutGroupContainers()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutGroupContainers()
    }

    private func layoutGroupContainers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        wantsLayer = true
        if groupContainersLayer.superlayer !== layer {
            groupContainersLayer.zPosition = -10
            layer?.insertSublayer(groupContainersLayer, at: 0)
        }
        groupContainersLayer.frame = bounds
        groupContainersLayer.isGeometryFlipped = layer?.isGeometryFlipped ?? isFlipped

        guard !groupContainerRegions.isEmpty, bounds.width > 8 else {
            groupContainerLayers.forEach { $0.removeFromSuperlayer() }
            groupContainerLayers.removeAll(keepingCapacity: true)
            return
        }

        let scheme: ColorScheme = groupContainerIsDark ? .dark : .light
        let resolver = SidebarAppearanceColorResolver()
        let labelColor = resolver.resolvedColor(.labelColor, for: scheme)
        let horizontalPad: CGFloat = 3
        let containerWidth = max(0, bounds.width - horizontalPad * 2)
        let cornerRadius: CGFloat = 8

        while groupContainerLayers.count < groupContainerRegions.count {
            let shapeLayer = CAShapeLayer()
            groupContainersLayer.addSublayer(shapeLayer)
            groupContainerLayers.append(shapeLayer)
        }
        while groupContainerLayers.count > groupContainerRegions.count {
            groupContainerLayers.removeLast().removeFromSuperlayer()
        }

        for (index, region) in groupContainerRegions.enumerated() {
            let shapeLayer = groupContainerLayers[index]
            guard region.startRow >= 0,
                  region.endRow >= region.startRow,
                  region.endRow < numberOfRows else {
                shapeLayer.isHidden = true
                continue
            }

            let startRect: CGRect
            let endCellRect: CGRect
            if numberOfColumns > 0 {
                startRect = frameOfCell(atColumn: 0, row: region.startRow)
                endCellRect = frameOfCell(atColumn: 0, row: region.endRow)
            } else {
                startRect = rect(ofRow: region.startRow)
                var fallbackEnd = rect(ofRow: region.endRow)
                fallbackEnd.size.height = max(0, fallbackEnd.height - intercellSpacing.height)
                endCellRect = fallbackEnd
            }

            let minY = startRect.minY
            let maxY = max(minY, endCellRect.maxY)
            let containerHeight = maxY - minY
            guard containerWidth > 2, containerHeight > 2 else {
                shapeLayer.isHidden = true
                continue
            }

            shapeLayer.isHidden = false
            let containerFrame = CGRect(
                x: horizontalPad,
                y: minY,
                width: containerWidth,
                height: containerHeight
            )
            shapeLayer.frame = containerFrame
            let strokeBounds = CGRect(origin: .zero, size: containerFrame.size).insetBy(dx: 0.5, dy: 0.5)
            shapeLayer.path = CGPath(
                roundedRect: strokeBounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            shapeLayer.lineWidth = 1

            let customTint = region.tintHex.flatMap { NSColor(hex: $0) }
            let categoryTint = customTint ?? groupContainerAccentColor.nsColor(for: scheme)
            let isExpandedWithMembers = region.endRow > region.startRow

            if let customTint {
                let strokeAlpha: CGFloat = groupContainerIsDark
                    ? (groupContainerIncreaseContrast ? 0.52 : 0.36)
                    : (groupContainerIncreaseContrast ? 0.46 : 0.30)
                shapeLayer.strokeColor = customTint.withAlphaComponent(strokeAlpha).cgColor
                let fillAlpha: CGFloat = isExpandedWithMembers
                    ? (groupContainerIsDark ? 0.045 : 0.035)
                    : 0
                shapeLayer.fillColor = customTint.withAlphaComponent(fillAlpha).cgColor
            } else {
                let strokeBase = categoryTint.blended(withFraction: 0.72, of: labelColor) ?? labelColor
                let strokeAlpha: CGFloat = groupContainerIsDark
                    ? (groupContainerIncreaseContrast ? 0.38 : 0.24)
                    : (groupContainerIncreaseContrast ? 0.32 : 0.20)
                shapeLayer.strokeColor = strokeBase.withAlphaComponent(strokeAlpha).cgColor
                let fillAlpha: CGFloat = isExpandedWithMembers
                    ? (groupContainerIsDark ? 0.032 : 0.025)
                    : 0
                shapeLayer.fillColor = labelColor.withAlphaComponent(fillAlpha).cgColor
            }
        }
    }

    /// Pointer location for hover recomputes that no event drove (content
    /// applies, menu close, viewport changes). Tracking events stop while a
    /// context menu or drag session runs, so the cached point can be where
    /// the pointer was when the menu opened. "Close Workspace" from a row
    /// menu then revealed the X on whichever row slid into that old spot.
    /// Read the live pointer instead, and only while the tracking area
    /// still has the pointer inside the table.
    var livePointerWindowLocation: NSPoint? {
        guard lastPointerWindowLocation != nil, let window else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        pointerTrackingArea = next
        SidebarReorderInteractionState.shared.register(table: self)
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerWindowLocation(nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else {
            super.otherMouseDown(with: event)
            return
        }
        workspaceController?.middleClick(row: row)
    }

    /// Preserves row clicks while promoting threshold-crossing empty-area presses to window drags.
    override func mouseDown(with event: NSEvent) {
        workspaceController?.prepareForMouseDown()
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        // Below the last row the press is window-drag territory. Single clicks
        // only: a double-click still belongs to doubleClickEmptyArea().
        if clickedRow < 0, event.clickCount == 1,
           emptyAreaWindowDragController.perform(with: event, in: self) != .passThrough {
            return
        }
        // No selection paint on press: the highlight applies on down-then-up
        // (owner ruling). The action fires on mouse-up and paints the
        // optimistic treatment there, so a press that becomes a drag or a
        // cancelled click never shows a speculative highlight at all.
        super.mouseDown(with: event)
        if event.clickCount == 2, clickedRow < 0 {
            workspaceController?.doubleClickEmptyArea()
        }
    }

    /// Focus Sidebar hands this list the keyboard: arrows step workspaces,
    /// Return and Escape go back to the selected workspace.
    override func keyDown(with event: NSEvent) {
        if AppDelegate.shared?.handleSidebarKeyboardKey(event, in: self) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row < 0 else { return super.menu(for: event) }
        return workspaceController?.emptyAreaMenu()
    }

    private func updatePointer(with event: NSEvent) {
        setPointerWindowLocation(event.locationInWindow)
    }

    func setPointerWindowLocation(_ point: NSPoint?) {
        lastPointerWindowLocation = point
        if point == nil {
            workspaceController?.pointerDidLeaveTable()
        } else {
            workspaceController?.recomputeHoveredRow(windowPoint: point)
        }
    }
}
