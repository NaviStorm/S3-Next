import Foundation

let urlString = "https://s3.fr1.next.ink/s3-next-ink/DiskNAS.hbk/tmp/"
if let url = URL(string: urlString) {
    print("AbsoluteString: \(url.absoluteString)")
    print("Path: '\(url.path)'")
    print("PathComponents: \(url.pathComponents)")

    let path = url.path
    let parts = path.components(separatedBy: "/")
    let joined = parts.joined(separator: "/")
    print("Joined from components: '\(joined)'")
}
