public import AppKit
internal import CmuxTerminalCore
public import Foundation
public import GhosttyKit

// MARK: - Shared viewport fitting

struct SharedViewportFitResult {
    let width: UInt32
    let height: UInt32
    let columns: Int
    let rows: Int
    let grantWidth: UInt32
    let grantHeight: UInt32
    let baseFont: Float
    let currentFont: Float
    let fontChanged: Bool

    static func passthrough(width: UInt32, height: UInt32) -> Self {
        .init(width: width, height: height, columns: 0, rows: 0, grantWidth: width, grantHeight: height, baseFont: 0, currentFont: 0, fontChanged: false)
    }

    static func passthrough(width: UInt32, height: UInt32, grantWidth: UInt32, grantHeight: UInt32) -> Self {
        .init(width: width, height: height, columns: 0, rows: 0, grantWidth: grantWidth, grantHeight: grantHeight, baseFont: 0, currentFont: 0, fontChanged: false)
    }

    static func grant(
        _ box: (width: UInt32, height: UInt32),
        columns: Int,
        rows: Int,
        baseFont: Float,
        currentFont: Float,
        fontChanged: Bool
    ) -> Self {
        .init(width: box.width, height: box.height, columns: columns, rows: rows, grantWidth: box.width, grantHeight: box.height, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
    }

    static func fallback(
        width: UInt32,
        height: UInt32,
        columns: Int,
        rows: Int,
        grant: (width: UInt32, height: UInt32),
        baseFont: Float,
        currentFont: Float,
        fontChanged: Bool
    ) -> Self {
        .init(width: width, height: height, columns: columns, rows: rows, grantWidth: grant.width, grantHeight: grant.height, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
    }
}

extension TerminalSurface {
    static func sharedViewportLimitMatches(
        current: (columns: Int, rows: Int)?,
        requestedColumns: Int,
        requestedRows: Int
    ) -> Bool {
        guard let current else { return false }
        return current.columns == max(1, requestedColumns) &&
            current.rows == max(1, requestedRows)
    }

    /// Caps the surface grid to a paired iPhone's viewport.
    ///
    /// - Returns: The actual cell grid applied after capping to the Mac pane, or
    ///   `nil` when no live runtime surface is available.
    @discardableResult
    @MainActor
    public func applySharedViewportLimit(
        columns: Int,
        rows: Int,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "applySharedViewportLimit") else {
            paneHost.setSharedViewportBorder(size: nil, drawRight: false, drawBottom: false)
            return nil
        }
        if ioMode.usesManualIO {
            // Remote/tmux mirrors keep legacy capping; their remote grid is
            // authoritative and font fitting is intentionally out of v1 scope.
            return applyManualMirrorViewportLimit(surface: surface, columns: columns, rows: rows, reason: reason)
        }
        let requestedLimit = (columns: max(1, columns), rows: max(1, rows))
        if Self.sharedViewportLimitMatches(
            current: sharedViewportCellLimit,
            requestedColumns: requestedLimit.columns,
            requestedRows: requestedLimit.rows
        ) {
            // Replaying the same logical viewport must never run the pixel/font
            // fitter again. Under transport delay a peer can repeat a report
            // after the first apply already landed; re-fitting the same cell
            // grid can round to alternating pixel boxes and every set_size
            // produces SIGWINCH + a full-screen TUI repaint.
            let currentSize = ghostty_surface_size(surface)
            #if DEBUG
            Self.sizeLog(
                "sharedViewportLimit.coalesced surface=\(id.uuidString.prefix(8)) " +
                "cells=\(requestedLimit.columns)x\(requestedLimit.rows) " +
                "live=\(max(Int(currentSize.columns), 1))x\(max(Int(currentSize.rows), 1)) " +
                "reason=\(reason)"
            )
            #endif
            return (
                columns: max(Int(currentSize.columns), 1),
                rows: max(Int(currentSize.rows), 1)
            )
        }
        sharedViewportCellLimit = requestedLimit
        let baseWidth = lastUncappedPixelWidth
        let baseHeight = lastUncappedPixelHeight
        let currentSize = ghostty_surface_size(surface)
        let fallbackPaneWidth = lastPixelWidth > 0 ? lastPixelWidth : currentSize.width_px
        let fallbackPaneHeight = lastPixelHeight > 0 ? lastPixelHeight : currentSize.height_px
        let fit = sharedViewportFittedSize(
            width: baseWidth > 0 ? baseWidth : fallbackPaneWidth,
            height: baseHeight > 0 ? baseHeight : fallbackPaneHeight,
            surface: surface,
            reason: reason
        )
        guard fit.width > 0, fit.height > 0 else { return nil }

        // A changed report can still resolve to the grid Ghostty already has
        // (for example when the Mac pane constrains both the old and new peer
        // limits to 72x60). Pixel fitting may propose a different box for that
        // same cell grid. Calling set_size for pixel-only drift updates the PTY
        // winsize and emits SIGWINCH, which is exactly the replay trigger in
        // #13474. Keep the live pixel box whenever the effective grid is
        // already current.
        let liveAfterFit = ghostty_surface_size(surface)
        let liveGrid = (
            columns: max(Int(liveAfterFit.columns), 1),
            rows: max(Int(liveAfterFit.rows), 1)
        )
        if Self.sharedViewportLimitMatches(
            current: liveGrid,
            requestedColumns: fit.columns,
            requestedRows: fit.rows
        ) {
            let liveWidth = liveAfterFit.width_px
            let liveHeight = liveAfterFit.height_px
            lastPixelWidth = liveWidth
            lastPixelHeight = liveHeight
            updateSharedViewportBorder(
                appliedWidth: liveWidth,
                appliedHeight: liveHeight,
                baseWidth: baseWidth > 0 ? baseWidth : liveWidth,
                baseHeight: baseHeight > 0 ? baseHeight : liveHeight
            )
            #if DEBUG
            Self.sizeLog(
                "sharedViewportLimit.gridCurrent surface=\(id.uuidString.prefix(8)) " +
                "cells=\(fit.columns)x\(fit.rows) proposedPx=\(fit.width)x\(fit.height) " +
                "livePx=\(liveWidth)x\(liveHeight) reason=\(reason)"
            )
            #endif
            if fit.fontChanged {
                ghostty_surface_refresh(surface)
            }
            return liveGrid
        }

        let appliedWidth = fit.width
        let appliedHeight = fit.height
        let sizeChanged = appliedWidth != lastPixelWidth || appliedHeight != lastPixelHeight
        updateSharedViewportBorder(
            appliedWidth: appliedWidth,
            appliedHeight: appliedHeight,
            baseWidth: baseWidth > 0 ? baseWidth : appliedWidth,
            baseHeight: baseHeight > 0 ? baseHeight : appliedHeight
        )

        #if DEBUG
        Self.sizeLog(
            "sharedViewportLimit surface=\(id.uuidString.prefix(8)) cells=\(columns)x\(rows) " +
            "capPx=\(fit.grantWidth)x\(fit.grantHeight) appliedPx=\(appliedWidth)x\(appliedHeight) " +
            "basePx=\(baseWidth)x\(baseHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "font=\(String(format: "%.2f", fit.baseFont))->\(String(format: "%.2f", fit.currentFont)) " +
            "changed=\((sizeChanged || fit.fontChanged) ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else {
            if fit.fontChanged {
                ghostty_surface_refresh(surface)
            }
            return (fit.columns, fit.rows)
        }
        applySurfaceSize(
            surface,
            width: appliedWidth,
            height: appliedHeight,
            caller: "shared.viewport.apply"
        )
        lastPixelWidth = appliedWidth
        lastPixelHeight = appliedHeight
        ghostty_surface_refresh(surface)
        return (fit.columns, fit.rows)
    }

    @MainActor
    private func applyManualMirrorViewportLimit(
        surface: ghostty_surface_t,
        columns: Int,
        rows: Int,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        let targetWidth = safePixelDimension(cellCount: columns, cellSize: cellWidth, nonGridPixels: horizontalNonGridPixels)
        let targetHeight = safePixelDimension(cellCount: rows, cellSize: cellHeight, nonGridPixels: verticalNonGridPixels)

        sharedViewportCellLimit = (columns: max(1, columns), rows: max(1, rows))
        let baseWidth = lastUncappedPixelWidth > 0 ? lastUncappedPixelWidth : targetWidth
        let baseHeight = lastUncappedPixelHeight > 0 ? lastUncappedPixelHeight : targetHeight
        let appliedWidth = min(targetWidth, baseWidth)
        let appliedHeight = min(targetHeight, baseHeight)
        let sizeChanged = appliedWidth != lastPixelWidth || appliedHeight != lastPixelHeight
        let appliedColumns = cellCount(pixelDimension: appliedWidth, cellSize: cellWidth, nonGridPixels: horizontalNonGridPixels)
        let appliedRows = cellCount(pixelDimension: appliedHeight, cellSize: cellHeight, nonGridPixels: verticalNonGridPixels)
        updateSharedViewportBorder(
            appliedWidth: appliedWidth,
            appliedHeight: appliedHeight,
            baseWidth: baseWidth,
            baseHeight: baseHeight
        )

        #if DEBUG
        Self.sizeLog(
            "sharedViewportLimit surface=\(id.uuidString.prefix(8)) cells=\(columns)x\(rows) " +
            "capPx=\(targetWidth)x\(targetHeight) appliedPx=\(appliedWidth)x\(appliedHeight) " +
            "basePx=\(baseWidth)x\(baseHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\(sizeChanged ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else { return (appliedColumns, appliedRows) }
        applySurfaceSize(
            surface,
            width: appliedWidth,
            height: appliedHeight,
            caller: "shared.viewport.manualMirror"
        )
        lastPixelWidth = appliedWidth
        lastPixelHeight = appliedHeight
        ghostty_surface_refresh(surface)
        return (appliedColumns, appliedRows)
    }

    /// The grid the pane would show without a shared-sizing cap or an
    /// assigned-grid pin.
    ///
    /// Otherwise this is Ghostty's live grid. Capped or pinned, the live cell
    /// metrics (scaled back from the fitted font to the base font when capped)
    /// are divided into the pane's own pixel size, so the Mac pane can keep
    /// reporting its real viewport while another participant owns the grid.
    ///
    /// - Returns: The natural grid, or `nil` without a live runtime surface.
    @MainActor
    public func naturalGridSize() -> (columns: Int, rows: Int)? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "naturalGridSize") else { return nil }
        let size = ghostty_surface_size(surface)
        let liveColumns = max(Int(size.columns), 1)
        let liveRows = max(Int(size.rows), 1)
        guard sharedViewportCellLimit != nil || assignedGrid != nil,
              lastUncappedPixelWidth > 0, lastUncappedPixelHeight > 0,
              size.cell_width_px > 0, size.cell_height_px > 0 else {
            return (liveColumns, liveRows)
        }
        var fontRatio = 1.0
        if let fit = sharedViewportFontFitState, fit.fittedRuntimePointSize > 0 {
            fontRatio = Double(fit.baseRuntimePointSize / fit.fittedRuntimePointSize)
        }
        let padWidth = max(0, Int(size.width_px) - liveColumns * Int(size.cell_width_px))
        let padHeight = max(0, Int(size.height_px) - liveRows * Int(size.cell_height_px))
        let cellWidth = Double(size.cell_width_px) * fontRatio
        let cellHeight = Double(size.cell_height_px) * fontRatio
        let columns = Int((Double(Int(lastUncappedPixelWidth) - padWidth) / cellWidth).rounded(.down))
        let rows = Int((Double(Int(lastUncappedPixelHeight) - padHeight) / cellHeight).rounded(.down))
        return (max(columns, 1), max(rows, 1))
    }

    /// A sizing sample for the pane's own grid (``naturalGridSize()``) rather
    /// than the capped or pinned grid Ghostty holds. A mirror reports this as
    /// its viewport, so it can still grow a shared grid it does not own.
    ///
    /// - Returns: The sample, or `nil` without a live runtime surface.
    @MainActor
    public func viewSizingSample() -> TerminalSurfaceRawSizingSample? {
        guard let sample = rawSizingSample() else { return nil }
        guard sharedViewportCellLimit != nil || assignedGrid != nil,
              lastUncappedPixelWidth > 0, lastUncappedPixelHeight > 0,
              let natural = naturalGridSize() else { return sample }
        return TerminalSurfaceRawSizingSample(
            columns: natural.columns,
            rows: natural.rows,
            cellWidthPx: sample.cellWidthPx,
            cellHeightPx: sample.cellHeightPx,
            surfaceWidthPx: Int(lastUncappedPixelWidth),
            surfaceHeightPx: Int(lastUncappedPixelHeight),
            viewBoundsPt: sample.viewBoundsPt,
            backingScale: sample.backingScale
        )
    }

    /// Removes the shared viewport cap and restores the uncapped size.
    ///
    /// - Returns: Whether the runtime surface size changed.
    @discardableResult
    @MainActor
    public func clearSharedViewportLimit(reason: String) -> Bool {
        sharedViewportCellLimit = nil
        paneHost.setSharedViewportBorder(size: nil, drawRight: false, drawBottom: false)

        guard let surface = liveSurfaceForGhosttyAccess(reason: "clearSharedViewportLimit") else {
            sharedViewportFontFitState = nil
            return false
        }
        _ = fontSizeLineageSnapshot()
        let fontRestored = restoreSharedViewportFitFontIfNeeded()
        let uncappedWidth = lastUncappedPixelWidth
        let uncappedHeight = lastUncappedPixelHeight
        guard uncappedWidth > 0, uncappedHeight > 0 else {
            if fontRestored {
                ghostty_surface_refresh(surface)
            }
            return fontRestored
        }

        let sizeChanged = uncappedWidth != lastPixelWidth || uncappedHeight != lastPixelHeight

        #if DEBUG
        Self.sizeLog(
            "clearSharedViewportLimit surface=\(id.uuidString.prefix(8)) " +
            "uncappedPx=\(uncappedWidth)x\(uncappedHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\((sizeChanged || fontRestored) ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else {
            ghostty_surface_refresh(surface)
            return fontRestored
        }
        applySurfaceSize(
            surface,
            width: uncappedWidth,
            height: uncappedHeight,
            caller: "shared.viewport.clear"
        )
        lastPixelWidth = uncappedWidth
        lastPixelHeight = uncappedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    @MainActor
    func sharedViewportFittedSize(
        width: UInt32,
        height: UInt32,
        surface: ghostty_surface_t,
        reason: String
    ) -> SharedViewportFitResult {
        guard width > 0, height > 0 else { return .passthrough(width: width, height: height) }
        guard let sharedViewportCellLimit else { return .passthrough(width: width, height: height) }
        if ioMode.usesManualIO {
            guard let limit = sharedViewportPixelLimit(for: surface) else { return .passthrough(width: width, height: height) }
            return .passthrough(width: min(width, limit.width), height: min(height, limit.height), grantWidth: limit.width, grantHeight: limit.height)
        }

        let grantedColumns = max(1, sharedViewportCellLimit.columns)
        let grantedRows = max(1, sharedViewportCellLimit.rows)
        let paneWidth = max(1, Int(width))
        let paneHeight = max(1, Int(height))
        _ = fontSizeLineageSnapshot()
        let baseFont = resolvedSharedViewportBaseFontPointSize(surface: surface)
        var currentFont = sharedViewportFontFitState?.fittedRuntimePointSize
            ?? GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface)
            ?? baseFont
        var measurement = sharedViewportMeasurement(surface: surface)
        var geometry = sharedViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
        var targetFont = geometry.integerCellTargetFontPointSize(
            baseFontPointSize: baseFont,
            currentFontPointSize: currentFont,
            columns: grantedColumns,
            rows: grantedRows
        )
        var fontChanged = false
        var appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)

        for _ in 0..<3 {
            let fontFloor = min(baseFont, SharedViewportFitGeometry.defaultFontFloorPointSize)
            if abs(targetFont - currentFont) >= 0.25 {
                if applySharedViewportFontPointSize(targetFont, baseFont: baseFont) {
                    currentFont = targetFont
                    fontChanged = true
                    measurement = sharedViewportMeasurement(surface: surface)
                    geometry = sharedViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
                }
            }

            appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)
            if !geometry.needsRefinement(grantWidthPx: appliedBox.width, grantHeightPx: appliedBox.height) {
                return .grant(appliedBox, columns: grantedColumns, rows: grantedRows, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
            }

            guard currentFont > fontFloor + 0.001 else {
                break
            }

            let nextTarget = geometry.correctiveFontPointSizeForOverflow(
                currentFontPointSize: currentFont,
                columns: grantedColumns,
                rows: grantedRows
            )
            guard abs(nextTarget - currentFont) > 0.001 else {
                break
            }
            if applySharedViewportFontPointSize(nextTarget, baseFont: baseFont) {
                currentFont = nextTarget
                fontChanged = true
                measurement = sharedViewportMeasurement(surface: surface)
                geometry = sharedViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
                targetFont = nextTarget
            } else {
                break
            }
        }

        appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)
        if !geometry.needsRefinement(grantWidthPx: appliedBox.width, grantHeightPx: appliedBox.height) {
            return .grant(appliedBox, columns: grantedColumns, rows: grantedRows, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
        }

        let fontFloor = min(baseFont, SharedViewportFitGeometry.defaultFontFloorPointSize)
        if currentFont > fontFloor + 0.001 {
            // This force-to-floor step can be the first font change of the fit
            // (every earlier apply may have been skipped or broken out of), so
            // it must capture the restore point like the loop branches do.
            guard applySharedViewportFontPointSize(fontFloor, baseFont: baseFont) else {
                let fallback = geometry.cappedFallbackGrant(grantedColumns: grantedColumns, grantedRows: grantedRows)
                return .fallback(width: fallback.width, height: fallback.height, columns: fallback.columns, rows: fallback.rows, grant: appliedBox, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
            }
            currentFont = fontFloor
            fontChanged = true
            measurement = sharedViewportMeasurement(surface: surface)
            geometry = sharedViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
        }
        appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)
        if !geometry.needsRefinement(grantWidthPx: appliedBox.width, grantHeightPx: appliedBox.height) {
            return .grant(appliedBox, columns: grantedColumns, rows: grantedRows, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
        }

        let fallback = geometry.cappedFallbackGrant(grantedColumns: grantedColumns, grantedRows: grantedRows)
        return .fallback(width: fallback.width, height: fallback.height, columns: fallback.columns, rows: fallback.rows, grant: appliedBox, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
    }

    private func sharedViewportPixelLimit(for surface: ghostty_surface_t) -> (width: UInt32, height: UInt32)? {
        guard let sharedViewportCellLimit else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        return (
            width: safePixelDimension(cellCount: sharedViewportCellLimit.columns, cellSize: cellWidth, nonGridPixels: horizontalNonGridPixels),
            height: safePixelDimension(cellCount: sharedViewportCellLimit.rows, cellSize: cellHeight, nonGridPixels: verticalNonGridPixels)
        )
    }

    private func safePixelDimension(cellCount: Int, cellSize: Int, nonGridPixels: Int) -> UInt32 {
        let clampedCellSize = max(1, cellSize)
        let clampedNonGridPixels = min(max(0, nonGridPixels), Int(UInt32.max) - 1)
        let maxCells = max(1, (Int(UInt32.max) - clampedNonGridPixels) / clampedCellSize)
        let clampedCellCount = min(max(1, cellCount), maxCells)
        return UInt32(clampedCellCount * clampedCellSize + clampedNonGridPixels)
    }

    private func cellCount(pixelDimension: UInt32, cellSize: Int, nonGridPixels: Int) -> Int {
        let gridPixels = max(0, Int(pixelDimension) - max(0, nonGridPixels))
        return max(1, gridPixels / max(1, cellSize))
    }

    @MainActor
    private func sharedViewportMeasurement(
        surface: ghostty_surface_t
    ) -> (
        cellWidth: Int,
        cellHeight: Int,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int
    ) {
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        return (
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            horizontalNonGridPixels: max(0, Int(size.width_px) - currentColumns * cellWidth),
            verticalNonGridPixels: max(0, Int(size.height_px) - currentRows * cellHeight)
        )
    }

    private func sharedViewportGeometry(
        paneWidth: Int,
        paneHeight: Int,
        measurement: (
            cellWidth: Int,
            cellHeight: Int,
            horizontalNonGridPixels: Int,
            verticalNonGridPixels: Int
        )
    ) -> SharedViewportFitGeometry {
        SharedViewportFitGeometry(
            paneWidthPx: paneWidth,
            paneHeightPx: paneHeight,
            cellWidthPx: Double(measurement.cellWidth),
            cellHeightPx: Double(measurement.cellHeight),
            horizontalNonGridPixels: measurement.horizontalNonGridPixels,
            verticalNonGridPixels: measurement.verticalNonGridPixels
        )
    }

    @MainActor
    private func resolvedSharedViewportBaseFontPointSize(surface: ghostty_surface_t) -> Float {
        if let sharedViewportFontFitState {
            return sharedViewportFontFitState.baseRuntimePointSize
        }
        if let current = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface),
           current.isFinite,
           current > 0 {
            return current
        }
        let baseFont = configTemplate?.fontSize ?? Float(GhosttyConfig().fontSize)
        return CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseFont > 0 ? baseFont : Float(GhosttyConfig().fontSize),
            percent: globalFontMagnificationPercent()
        )
    }

    @discardableResult
    @MainActor
    private func restoreSharedViewportFitFontIfNeeded() -> Bool {
        guard sharedViewportFontFitState != nil else {
            return false
        }
        let restored: Bool
        if let lineage = lastKnownFontSizeLineage,
           lineage.isExplicitOverride {
            // Lineage stores unscaled base points, so restoration intentionally
            // reapplies the current global magnification.
            let runtimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(
                fromBasePoints: lineage.basePoints,
                percent: globalFontMagnificationPercent()
            )
            restored = performSharedViewportFontPointSizeAction(runtimePoints)
        } else {
            restored = performInternalBindingAction("reset_font_size")
        }
        guard restored else {
            // Keep the fit state when the binding action fails so a later
            // clear or fit pass can retry; dropping it here would leave the
            // pane at the shrunken font with no way back to the base size.
            return false
        }
        sharedViewportFontFitState = nil
        return true
    }

    @MainActor
    @discardableResult
    private func applySharedViewportFontPointSize(_ points: Float, baseFont: Float) -> Bool {
        guard performSharedViewportFontPointSizeAction(points) else { return false }
        if sharedViewportFontFitState == nil {
            sharedViewportFontFitState = SharedViewportFontFitState(
                baseRuntimePointSize: baseFont,
                fittedRuntimePointSize: points
            )
        } else {
            sharedViewportFontFitState?
                .updateViewportFit(to: points)
        }
        return true
    }

    @MainActor
    func performSharedViewportFontPointSizeAction(_ points: Float) -> Bool {
        let action =
            ghosttySetFontSizeBindingAction(points)
        return performInternalBindingAction(action)
    }

    @MainActor
    func updateSharedViewportBorder(
        appliedWidth: UInt32,
        appliedHeight: UInt32,
        baseWidth: UInt32,
        baseHeight: UInt32
    ) {
        let drawRightBorder = appliedWidth < baseWidth
        let drawBottomBorder = appliedHeight < baseHeight
        let borderScale = paneHost.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        paneHost.setSharedViewportBorder(
            size: CGSize(
                width: CGFloat(appliedWidth) / max(1, borderScale),
                height: CGFloat(appliedHeight) / max(1, borderScale)
            ),
            drawRight: drawRightBorder,
            drawBottom: drawBottomBorder
        )
    }
}
