//
//  S3_VueApp.swift
//  S3 Vue
//
//  Created by Andreu Ascensio Thierry on 21/01/2026.
//

import SwiftUI
import CoreData

@main
struct S3_VueApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
