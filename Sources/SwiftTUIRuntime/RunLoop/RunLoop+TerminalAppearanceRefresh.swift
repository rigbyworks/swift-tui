import SwiftTUICore

extension RunLoop {
  /// Follows the terminal's colour-scheme reports for this session: each one
  /// re-probes the colours and, when they changed, redraws everything. Only a
  /// real terminal host with a live reader takes part.
  func startTerminalAppearanceRefresh() {
    #if !canImport(WASILibc)
      guard let host = presentationSurface as? TerminalHost,
        let reader = terminalInputReader as? InputReader
      else {
        return
      }
      let refresher = TerminalAppearanceRefresher(host: host) { [weak self] in
        self?.redrawForTerminalAppearanceChange()
      }
      refresher.attach(to: reader)
      terminalAppearanceRefresher = refresher
    #endif
  }

  func stopTerminalAppearanceRefresh() {
    #if !canImport(WASILibc)
      terminalAppearanceRefresher?.cancel()
      terminalAppearanceRefresher = nil
    #endif
  }

  /// Every synthesized colour derives from the appearance, so nothing kept
  /// from the last frame is still right: forget the presented baseline and
  /// force the next frame through root evaluation.
  private func redrawForTerminalAppearanceChange() {
    previousPresentedRasterSurface = nil
    renderer.forceRootEvaluation(source: .terminalAppearance)
    scheduler.requestInvalidation(of: [rootIdentity])
    scheduler.requestExternalWake(reason: "terminal-appearance-changed")
  }
}
