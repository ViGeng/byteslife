import AppKit

// Top-level entry point. A file named main.swift uses top-level code and never @main, so it can run
// this setup before handing control to SwiftUI.
//
// .accessory keeps ByteLife out of the Dock and the app switcher even under `swift run`, which is the
// correct posture for a menubar-only app. The packaged bundle also sets LSUIElement, but doing it here
// too means the unpackaged binary behaves the same.
NSApplication.shared.setActivationPolicy(.accessory)
ByteLifeApplication.main()
