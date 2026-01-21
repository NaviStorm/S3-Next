import Combine
import Foundation
import SwiftUI

final class S3AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Config
    @Published var accessKey = ""
    @Published var secretKey = ""
    @Published var bucket = ""
    @Published var region = "us-east-1"
    @Published var endpoint = "https://s3.fr1.next.ink"  // Default or empty
    @Published var usePathStyle = true
    @Published var debugMessage: String = ""  // For debugging

    // Smart Logging Helper
    func log(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        let fileName = (file as NSString).lastPathComponent
        let logEntry = "[\(fileName):\(line)] \(function) > \(message)\n"

        if Thread.isMainThread {
            self.debugMessage += logEntry
        } else {
            DispatchQueue.main.async {
                self.debugMessage += logEntry
            }
        }
    }

    // Data
    @Published var currentPath: [String] = []  // Navigation stack (folders)
    @Published var objects: [S3Object] = []

    private var client: S3Client?

    private let kService = "com.antigravity.s3viewer"
    private let kAccount = "aws-secret"

    init() {
        loadConfig()
    }

    func loadConfig() {
        if let savedAccess = UserDefaults.standard.string(forKey: "accessKey") {
            accessKey = savedAccess
        }
        if let savedBucket = UserDefaults.standard.string(forKey: "bucket") { bucket = savedBucket }
        if let savedRegion = UserDefaults.standard.string(forKey: "region") { region = savedRegion }
        if let savedEndpoint = UserDefaults.standard.string(forKey: "endpoint") {
            endpoint = savedEndpoint
        }
        if UserDefaults.standard.object(forKey: "usePathStyle") != nil {
            usePathStyle = UserDefaults.standard.bool(forKey: "usePathStyle")
        }
        if let savedSecret = KeychainHelper.shared.read(service: kService, account: kAccount) {
            secretKey = savedSecret
        }
    }

    func connect() async {
        log("connect() called. Resetting state...")
        DispatchQueue.main.async {
            self.saveConfig()  // Save immediately when user clicks Connect
            self.isLoading = true
            self.errorMessage = nil
        }

        let newClient = S3Client(
            accessKey: accessKey, secretKey: secretKey, region: region, bucket: bucket,
            endpoint: endpoint, usePathStyle: usePathStyle)

        log("S3Client initialized. Testing connection to bucket: \(self.bucket)...")

        do {
            // Test connection by listing root
            let _ = try await newClient.listObjects(prefix: "")
            log("Connection test successful (Root listed).")

            DispatchQueue.main.async {
                self.log("Connection confirmed. Switching to logged in state.")
                self.client = newClient
                self.isLoggedIn = true
                self.isLoading = false
                self.saveConfig()
                self.loadObjects()
            }
        } catch {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "Connection failed: \(error.localizedDescription)"
                self.log("[Connection Error] \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        isLoggedIn = false
        client = nil
        objects = []
        currentPath = []
    }

    func loadObjects() {
        guard let client = client else { return }

        isLoading = true
        let prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"

        log("LOADING: \(prefix)")

        Task {
            do {
                let (fetchedObjects, debugInfo) = try await client.listObjects(prefix: prefix)
                DispatchQueue.main.async {
                    self.objects = fetchedObjects
                    self.log("Objects fetched. Parser logs: \n" + debugInfo)
                    self.isLoading = false
                    // Force show debug message if recursion suspect
                    if fetchedObjects.contains(where: { $0.key.hasPrefix(prefix + prefix) }) {  // Heuristic
                        self.errorMessage = "Potential Recursion Detected"
                    } else if !debugInfo.isEmpty {
                        self.errorMessage = "Debug Info Available"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to list objects: \(error.localizedDescription)"
                    self.log("ERROR: \(error.localizedDescription)")
                    self.isLoading = false

                    // Auto-revert path on failure if not root
                    if !self.currentPath.isEmpty {
                        self.currentPath.removeLast()
                        self.log("-> Reverted path due to error.")
                    }
                }
            }
        }
    }

    func navigateTo(folder: String) {
        let cleanFolder = folder.replacingOccurrences(of: "/", with: "")
        guard !cleanFolder.isEmpty else { return }

        currentPath.append(cleanFolder)
        log("NAVIGATING TO: '\(cleanFolder)'")
        loadObjects()
    }

    func navigateBack() {
        if !currentPath.isEmpty {
            currentPath.removeLast()
            loadObjects()
        }
    }

    func navigateHome() {
        currentPath.removeAll()
        loadObjects()
    }

    func downloadFile(key: String) {
        guard let client = client else { return }
        isLoading = true
        log("[Download START] \(key)")
        Task {
            do {
                let (data, logs) = try await client.fetchObjectData(key: key)
                DispatchQueue.main.async {
                    self.log(logs)
                    self.log("[Download SUCCESS] Size: \(data.count) bytes")
                    self.saveFileToDisk(
                        data: data, filename: key.components(separatedBy: "/").last ?? "download")
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    self.log("[Download ERROR] \(error.localizedDescription)")
                    self.isLoading = false
                }
            }
        }
    }

    private func saveConfig() {
        UserDefaults.standard.set(accessKey, forKey: "accessKey")
        UserDefaults.standard.set(bucket, forKey: "bucket")
        UserDefaults.standard.set(region, forKey: "region")
        UserDefaults.standard.set(endpoint, forKey: "endpoint")
        UserDefaults.standard.set(usePathStyle, forKey: "usePathStyle")
        KeychainHelper.shared.save(secretKey, service: kService, account: kAccount)
    }

    private func saveFileToDisk(data: Data, filename: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }
}
