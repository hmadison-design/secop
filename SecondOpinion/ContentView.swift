//
//  ContentView.swift
//  SecondOpinion
//
//  Created by Harvey Madison on 12/6/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        WebView(htmlFileName: "index")
            .ignoresSafeArea() // Let your web app use the full screen
    }
}

#Preview {
    ContentView()
}
