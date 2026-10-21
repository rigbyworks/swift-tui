import SwiftTUICore

#if !canImport(WASILibc)
  /// Keeps a terminal host's colours current while the run loop runs.
  ///
  /// A colour-scheme report (DEC mode 2031) only says the colours may have
  /// changed. Ghostty's follows the OS appearance, not the theme's real
  /// luminance, so the dark/light flag is ignored: each report re-asks for
  /// OSC 10, 11 and 4, and the replies decide. Mid-run the live reader owns
  /// the input, so the replies come back through its parser rather than a
  /// blocking read, and keys typed in the meantime still reach the app. A
  /// device attributes reply closes the batch; a timeout closes it for
  /// terminals that never send one.
  ///
  /// Reports that arrive while a refresh is waiting to start fold into it.
  /// Reports that arrive while one is in flight fold into a single follow-up.
  ///
  /// Replies carry nothing that ties them to a batch. When a batch times out,
  /// its late replies may still be on the way, so no new batch starts until
  /// that batch's device attributes reply arrives or a second timeout passes,
  /// and colour replies in the meantime are dropped.
  @MainActor
  package final class TerminalAppearanceRefresher {
    private let host: TerminalHost
    private let debounce: Duration
    private let replyTimeout: Duration
    private let onAppearanceChange: @MainActor () -> Void

    private var scheduledRefresh: Task<Void, Never>?
    private var replyDeadline: Task<Void, Never>?
    /// The replies collected so far; `nil` when no refresh is in flight.
    private var replies: [TerminalAppearanceQuery: Color]?
    /// `true` while the late replies of a timed-out batch may still arrive.
    private var drainsTimedOutBatch = false
    private var refreshesAfterReplies = false

    private var reader: InputReader?
    private var reportStream: AsyncStream<[TerminalInputReport]>.Continuation?
    private var reportPump: Task<Void, Never>?

    package init(
      host: TerminalHost,
      debounce: Duration = .milliseconds(50),
      replyTimeout: Duration = .seconds(1),
      onAppearanceChange: @escaping @MainActor () -> Void
    ) {
      self.host = host
      self.debounce = debounce
      self.replyTimeout = replyTimeout
      self.onAppearanceChange = onAppearanceChange
    }

    /// Takes the reports `reader` parses, in the order they arrive.
    package func attach(to reader: InputReader) {
      let (reports, continuation) = AsyncStream.makeStream(of: [TerminalInputReport].self)
      reader.setTerminalReportHandler { continuation.yield($0) }
      self.reader = reader
      reportStream = continuation
      reportPump = Task { [weak self] in
        for await batch in reports {
          self?.receive(batch)
        }
      }
    }

    /// Detaches from the reader and drops any pending or in-flight refresh.
    package func cancel() {
      reader?.setTerminalReportHandler(nil)
      reader = nil
      reportStream?.finish()
      reportStream = nil
      reportPump?.cancel()
      reportPump = nil
      scheduledRefresh?.cancel()
      scheduledRefresh = nil
      replyDeadline?.cancel()
      replyDeadline = nil
      replies = nil
      drainsTimedOutBatch = false
      refreshesAfterReplies = false
    }

    package func receive(_ reports: [TerminalInputReport]) {
      for report in reports {
        switch report {
        case .colorSchemeChanged:
          if replies != nil || drainsTimedOutBatch {
            refreshesAfterReplies = true
          } else {
            scheduleRefresh()
          }
        case .color(let query, let color):
          replies?[query] = color
        case .primaryDeviceAttributes:
          if drainsTimedOutBatch {
            finishDraining()
          } else {
            finishRefresh()
          }
        }
      }
    }

    private func scheduleRefresh() {
      guard scheduledRefresh == nil else {
        return
      }
      let debounce = debounce
      scheduledRefresh = Task { [weak self] in
        try? await Task.sleep(for: debounce)
        guard !Task.isCancelled else {
          return
        }
        self?.startRefresh()
      }
    }

    private func startRefresh() {
      scheduledRefresh = nil
      replies = [:]
      guard (try? host.requestAppearanceRefresh()) == true else {
        replies = nil
        return
      }
      let replyTimeout = replyTimeout
      replyDeadline = Task { [weak self] in
        try? await Task.sleep(for: replyTimeout)
        guard !Task.isCancelled else {
          return
        }
        self?.finishRefresh(timedOut: true)
      }
    }

    private func finishRefresh(timedOut: Bool = false) {
      guard let replies else {
        return
      }
      self.replies = nil
      replyDeadline?.cancel()
      replyDeadline = nil
      if host.applyAppearanceReplies(replies) {
        onAppearanceChange()
      }
      if timedOut {
        drainsTimedOutBatch = true
        let replyTimeout = replyTimeout
        replyDeadline = Task { [weak self] in
          try? await Task.sleep(for: replyTimeout)
          guard !Task.isCancelled else {
            return
          }
          self?.finishDraining()
        }
      } else {
        refreshIfReported()
      }
    }

    private func finishDraining() {
      guard drainsTimedOutBatch else {
        return
      }
      drainsTimedOutBatch = false
      replyDeadline?.cancel()
      replyDeadline = nil
      refreshIfReported()
    }

    private func refreshIfReported() {
      if refreshesAfterReplies {
        refreshesAfterReplies = false
        scheduleRefresh()
      }
    }
  }
#endif
