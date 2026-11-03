//
//  GrokNotchHarness.swift
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import Foundation
import DroppyKit
import DroppyKitHarness
import GrokNotch

@main
struct GrokNotchHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet {
        let droplet = GrokNotchDroplet()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-message") { droplet.prepareMessagePreviewForHarness() }
        #endif
        return droplet
    }
}
