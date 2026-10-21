// Excluded from Windows builds: the routing test drives the POSIX
// dispatch-source InputReader through a pipe.
#if !os(Windows)

  import Synchronization
  import Testing

  @testable import SwiftTUICore
  @_spi(Runners) @testable import SwiftTUIRuntime

  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif

  /// DEC mode 2031 colour-scheme reports: the parser keeps them (and the
  /// colour-query replies a refresh asks for) out of the key stream, the host
  /// sets and clears the mode with raw mode, and a report re-probes the
  /// colours mid-run.
  @MainActor
  @Suite
  struct TerminalColorSchemeReportTests {
    private static let darkReport = Array("\u{001B}[?997;1n".utf8)
    private static let lightReport = Array("\u{001B}[?997;2n".utf8)
    private static let lightReplies = Array(
      ("\u{001B}]10;rgb:0000/0000/0000\u{001B}\\"
        + "\u{001B}]11;rgb:f7f7/f7f7/f7f7\u{0007}"
        + "\u{001B}]4;4;rgb:0000/5555/dddd\u{0007}"
        + "\u{001B}[?62;22c").utf8
    )
    private static let lightBackground = Color(hexRGB: 0xF7F7F7)

    // MARK: - Parsing

    @Test("A whole report becomes a report, never a key", arguments: [true, false])
    func wholeReport(isDark: Bool) {
      var parser = TerminalInputParser()
      let events = parser.feed(isDark ? Self.darkReport : Self.lightReport)
      #expect(events.isEmpty)
      #expect(parser.takeReports() == [.colorSchemeChanged(isDark: isDark)])
    }

    @Test("A report split at any byte becomes one report and no keys")
    func splitReport() {
      for split in 1..<Self.lightReport.count {
        var parser = TerminalInputParser()
        let head = parser.feed(Array(Self.lightReport[..<split]))
        let headReports = parser.takeReports()
        let tail = parser.feed(Array(Self.lightReport[split...]))
        #expect(head.isEmpty, "split at \(split)")
        #expect(tail.isEmpty, "split at \(split)")
        #expect(headReports + parser.takeReports() == [.colorSchemeChanged(isDark: false)])
      }
    }

    @Test("Keys on either side of a report arrive intact")
    func reportBetweenKeys() {
      var parser = TerminalInputParser()
      let events = parser.feed(Array("a".utf8) + Self.darkReport + Array("b".utf8))
      #expect(events == [.key(.character("a")), .key(.character("b"))])
      #expect(parser.takeReports() == [.colorSchemeChanged(isDark: true)])
    }

    @Test("The 8-bit CSI form is recognized too")
    func eightBitReport() {
      var parser = TerminalInputParser()
      #expect(parser.feed([0x9B] + Array("?997;2n".utf8)).isEmpty)
      #expect(parser.takeReports() == [.colorSchemeChanged(isDark: false)])
    }

    @Test("Other private n replies are swallowed without a report")
    func unrelatedPrivateReport() {
      var parser = TerminalInputParser()
      #expect(parser.feed(Array("\u{001B}[?997;3n\u{001B}[?6n".utf8)).isEmpty)
      #expect(parser.takeReports().isEmpty)
    }

    @Test("Colour replies and the closing device attributes become reports")
    func colourReplies() throws {
      var parser = TerminalInputParser()
      // Split between the ESC and backslash of the first reply's ST.
      #expect(parser.feed(Array(Self.lightReplies[..<24])).isEmpty)
      var reports = parser.takeReports()
      #expect(parser.feed(Array(Self.lightReplies[24...])).isEmpty)
      reports += parser.takeReports()
      #expect(
        reports == [
          .color(.foreground, Color(hexRGB: 0x000000)),
          .color(.background, Self.lightBackground),
          .color(.palette(index: 4), Color(hexRGB: 0x0055DD)),
          .primaryDeviceAttributes,
        ])
    }

    @Test("Each feed drops the reports the previous one left untaken")
    func untakenReportsDoNotAccumulate() {
      var parser = TerminalInputParser()
      _ = parser.feed(Self.darkReport)
      _ = parser.feed(Array("x".utf8))
      #expect(parser.takeReports().isEmpty)
    }

    // MARK: - Mode 2031 writes

    @Test("Raw mode sets 2031 after the startup probes and clears it before leaving")
    func rawModeWrites() throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)

      try host.enableRawMode()
      let entered = controller.writes.joined()
      // The startup colour probe ran first, and 2031 is the very last write.
      #expect(entered.contains("\u{001B}]4;8;?\u{0007}"))
      #expect(entered.contains("\u{001B}[?1049h"))
      #expect(entered.hasSuffix("\u{001B}[?2031h"))

      controller.clearWrites()
      try host.disableRawMode()
      let left = controller.writes.joined()
      let disable = try #require(left.firstLiteralRange(of: "\u{001B}[?2031l"))
      let exit = try #require(left.firstLiteralRange(of: "\u{001B}[?1049l"))
      #expect(disable.upperBound <= exit.lowerBound)
    }

    @Test("A terminal handoff clears 2031, then sets it again and asks for the scheme")
    func handoffRoundTrip() throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      #expect(!controller.writes.joined().contains("\u{001B}[?996n"))
      try host.disableRawMode()
      controller.clearWrites()

      try host.enableRawMode()
      // The scheme may have changed while reports were off.
      #expect(controller.writes.joined().hasSuffix("\u{001B}[?2031h\u{001B}[?996n"))
      #expect(controller.backgroundQueryCount == 0)
      try host.disableRawMode()
      #expect(controller.writes.joined().hasSuffix("\u{001B}[?1049l"))
      #expect(controller.writes.joined().contains("\u{001B}[?2031l"))
    }

    @Test("Crash-path reset bytes clear 2031 only while it is set")
    func processExitReset() {
      let set = TerminalHostEscapeSequences.processExitReset(
        mouseCoordinateMode: .cells,
        hoverEnabled: false,
        kittyKeyboardPushed: false,
        colorSchemeReportsEnabled: true
      )
      #expect(set.contains("\u{001B}[?2031l"))
      let unset = TerminalHostEscapeSequences.processExitReset(
        mouseCoordinateMode: .cells,
        hoverEnabled: false,
        kittyKeyboardPushed: false
      )
      #expect(!unset.contains("\u{001B}[?2031l"))
    }

    // MARK: - Re-probe

    @Test("A refresh writes only the colour queries, closed by a device attributes query")
    func refreshWritesQueries() throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      #expect(try host.requestAppearanceRefresh() == false)
      #expect(controller.writes.isEmpty)

      try host.enableRawMode()
      controller.clearWrites()
      #expect(try host.requestAppearanceRefresh())
      #expect(
        controller.writes.joined()
          == TerminalAppearanceQuery.probed.map(\.request).joined() + "\u{001B}[c")
    }

    @Test("A report re-probes, and the replies rebuild the appearance and theme")
    func reportUpdatesTheme() async throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      controller.clearWrites()
      let darkTheme = host.appearance.synthesizedTheme()
      let changes = LockedBox(0)
      let refresher = TerminalAppearanceRefresher(
        host: host, debounce: .zero, replyTimeout: .seconds(30)
      ) {
        changes.withLock { $0 += 1 }
      }
      defer { refresher.cancel() }

      refresher.receive([.colorSchemeChanged(isDark: false)])
      try await waitUntil { controller.backgroundQueryCount == 1 }
      #expect(changes.value == 0)

      var parser = TerminalInputParser()
      _ = parser.feed(Self.lightReplies)
      refresher.receive(parser.takeReports())

      #expect(changes.value == 1)
      #expect(host.appearance.backgroundColor == Self.lightBackground)
      #expect(host.appearance.foregroundColor == Color(hexRGB: 0x000000))
      #expect(host.appearance.tintColor == Color(hexRGB: 0x0055DD))
      let lightTheme = host.appearance.synthesizedTheme()
      #expect(lightTheme != darkTheme)
      #expect(lightTheme.background == Self.lightBackground)
      #expect(lightTheme.separator != darkTheme.separator)
      #expect(lightTheme.selection != darkTheme.selection)
    }

    @Test("Reports close together collapse into one re-probe")
    func reportsCollapse() async throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      controller.clearWrites()
      let refresher = TerminalAppearanceRefresher(
        host: host, debounce: .milliseconds(30), replyTimeout: .seconds(30)
      ) {}
      defer { refresher.cancel() }

      refresher.receive([.colorSchemeChanged(isDark: true)])
      refresher.receive([.colorSchemeChanged(isDark: false), .colorSchemeChanged(isDark: true)])
      try await waitUntil { controller.backgroundQueryCount == 1 }
      // Reports while the queries are out fold into a single follow-up.
      refresher.receive([.colorSchemeChanged(isDark: false)])
      refresher.receive([.colorSchemeChanged(isDark: true)])
      try await Task.sleep(for: .milliseconds(100))
      #expect(controller.backgroundQueryCount == 1)

      refresher.receive([.primaryDeviceAttributes])
      try await waitUntil { controller.backgroundQueryCount == 2 }
      refresher.receive([.primaryDeviceAttributes])
      try await Task.sleep(for: .milliseconds(100))
      #expect(controller.backgroundQueryCount == 2)
    }

    @Test("Without a device attributes reply the timeout applies what did arrive")
    func timeoutAppliesPartialReplies() async throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      controller.clearWrites()
      let changes = LockedBox(0)
      let refresher = TerminalAppearanceRefresher(
        host: host, debounce: .zero, replyTimeout: .milliseconds(500)
      ) {
        changes.withLock { $0 += 1 }
      }
      defer { refresher.cancel() }

      refresher.receive([.colorSchemeChanged(isDark: false)])
      try await waitUntil { controller.backgroundQueryCount == 1 }
      refresher.receive([.color(.background, Self.lightBackground)])
      try await waitUntil { changes.value == 1 }
      #expect(host.appearance.backgroundColor == Self.lightBackground)
    }

    @Test("Late replies from a timed-out batch never fill the next one")
    func lateRepliesDoNotFillNextBatch() async throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      controller.clearWrites()
      let changes = LockedBox(0)
      let refresher = TerminalAppearanceRefresher(
        host: host, debounce: .zero, replyTimeout: .seconds(2)
      ) {
        changes.withLock { $0 += 1 }
      }
      defer { refresher.cancel() }
      let staleBackground = Color(hexRGB: 0x101010)

      // The batch times out with only part of its replies back.
      refresher.receive([.colorSchemeChanged(isDark: false)])
      try await waitUntil { controller.backgroundQueryCount == 1 }
      refresher.receive([.color(.foreground, Color(hexRGB: 0x000000))])
      try await waitUntil { changes.value == 1 }

      // A report while its late replies may still come waits for them.
      refresher.receive([.colorSchemeChanged(isDark: false)])
      try await Task.sleep(for: .milliseconds(50))
      #expect(controller.backgroundQueryCount == 1)

      // The first batch's late replies land and close it out.
      refresher.receive([.color(.background, staleBackground), .primaryDeviceAttributes])
      try await waitUntil { controller.backgroundQueryCount == 2 }
      #expect(changes.value == 1)

      refresher.receive([.color(.background, Self.lightBackground), .primaryDeviceAttributes])
      #expect(changes.value == 2)
      #expect(host.appearance.backgroundColor == Self.lightBackground)
    }

    @Test("A timed-out batch whose replies never come stops blocking after a second timeout")
    func drainingEndsAfterSecondTimeout() async throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      controller.clearWrites()
      let refresher = TerminalAppearanceRefresher(
        host: host, debounce: .zero, replyTimeout: .milliseconds(200)
      ) {}
      defer { refresher.cancel() }

      refresher.receive([.colorSchemeChanged(isDark: false)])
      try await waitUntil { controller.backgroundQueryCount == 1 }
      try await Task.sleep(for: .milliseconds(300))
      refresher.receive([.colorSchemeChanged(isDark: true)])
      try await waitUntil { controller.backgroundQueryCount == 2 }
    }

    @Test("Replies that match the current colours do not redraw")
    func unchangedRepliesDoNotRedraw() async throws {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      controller.clearWrites()
      let changes = LockedBox(0)
      let refresher = TerminalAppearanceRefresher(
        host: host, debounce: .zero, replyTimeout: .seconds(30)
      ) {
        changes.withLock { $0 += 1 }
      }
      defer { refresher.cancel() }

      refresher.receive([.colorSchemeChanged(isDark: true)])
      try await waitUntil { controller.backgroundQueryCount == 1 }
      refresher.receive([
        .color(.background, host.appearance.backgroundColor), .primaryDeviceAttributes,
      ])
      #expect(changes.value == 0)
    }

    @Test("Replies with no refresh in flight are ignored")
    func strayRepliesIgnored() {
      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      let before = host.appearance
      let refresher = TerminalAppearanceRefresher(host: host) {}
      refresher.receive([.color(.background, Self.lightBackground), .primaryDeviceAttributes])
      #expect(host.appearance == before)
      #expect(controller.writes.isEmpty)
    }

    @Test("A live reader routes split reports to the refresher and keys to the app")
    func liveReaderRouting() async throws {
      var descriptors: [Int32] = [0, 0]
      try #require(unsafe pipe(&descriptors) == 0)
      let readDescriptor = descriptors[0]
      let writeDescriptor = descriptors[1]
      defer {
        _ = close(readDescriptor)
        _ = close(writeDescriptor)
      }
      let flags = fcntl(readDescriptor, F_GETFL)
      try #require(fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0)

      let controller = ColorSchemeMockTerminalController()
      let host = makeHost(controller: controller)
      try host.enableRawMode()
      controller.clearWrites()
      let changes = LockedBox(0)
      let refresher = TerminalAppearanceRefresher(
        host: host, debounce: .zero, replyTimeout: .seconds(30)
      ) {
        changes.withLock { $0 += 1 }
      }
      defer { refresher.cancel() }
      let reader = InputReader(fileDescriptor: readDescriptor)
      refresher.attach(to: reader)
      var iterator = reader.inputEvents().makeAsyncIterator()

      try writeBytes(Array("a".utf8) + Self.lightReport[..<5], to: writeDescriptor)
      let first = await iterator.next()
      #expect(first == .key(.character("a")))
      try writeBytes(Array(Self.lightReport[5...]), to: writeDescriptor)
      try await waitUntil { controller.backgroundQueryCount == 1 }

      try writeBytes(Self.lightReplies + Array("b".utf8), to: writeDescriptor)
      let second = await iterator.next()
      #expect(second == .key(.character("b")))
      try await waitUntil { changes.value == 1 }
      #expect(host.appearance.backgroundColor == Self.lightBackground)
    }

    // MARK: - Support

    private func makeHost(controller: ColorSchemeMockTerminalController) -> TerminalHost {
      TerminalHost(
        inputFileDescriptor: 0,
        outputFileDescriptor: 1,
        fallbackSize: .init(width: 80, height: 24),
        controller: controller,
        capabilityProfile: .trueColor,
        environment: ["TERM": "xterm-256color"]
      )
    }

    private func waitUntil(
      _ condition: () -> Bool,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      // Generous: under the full suite the main actor can be starved for many seconds.
      let deadline = ContinuousClock.now + .seconds(30)
      while !condition() {
        guard ContinuousClock.now < deadline else {
          Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
          return
        }
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    private func writeBytes(_ bytes: [UInt8], to fileDescriptor: Int32) throws {
      let written = bytes.withUnsafeBytes { buffer in
        unsafe write(fileDescriptor, buffer.baseAddress, buffer.count)
      }
      try #require(written == bytes.count)
    }
  }

  /// TTY mock that records writes and answers no queries, so the startup
  /// probes time out at once and every write the test sees is the host's.
  private final class ColorSchemeMockTerminalController: TerminalControlling {
    private let writesStorage = LockedBox<[String]>([])

    var writes: [String] {
      writesStorage.value
    }

    var backgroundQueryCount: Int {
      writes.filter { $0.contains("\u{001B}]11;?\u{0007}") }.count
    }

    func clearWrites() {
      writesStorage.value = []
    }

    func isATTY(_: Int32) -> Bool {
      true
    }

    func enterRawMode(input _: Int32, output _: Int32) throws -> TerminalModeSnapshot {
      TerminalModeSnapshot()
    }

    func restore(_: TerminalModeSnapshot, input _: Int32, output _: Int32) throws {}

    func windowSize(of _: Int32) throws -> CellSize {
      .init(width: 80, height: 24)
    }

    func write(_ output: String, to _: Int32) throws {
      writesStorage.withLock { $0.append(output) }
    }

    func read(from _: Int32, maxBytes _: Int, timeoutMilliseconds _: Int) throws -> [UInt8] {
      []
    }
  }

#endif
