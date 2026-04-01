//
//  SelectionOutlineApp.swift
//  SelectionOutline
//

import ComposableArchitecture
import SwiftUI

@main
struct SelectionOutlineApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView(
        store: Store(initialState: SelectionOutlineFeature.State()) {
          SelectionOutlineFeature()
        }
      )
    }
  }
}
