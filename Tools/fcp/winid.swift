// winid: list an app's on-screen windows as "id name x y w h", one per line, so a
// capture can target the main window. Final Cut Pro by default; `winid Phraseo` for
// another owner. Built by Tools/fcp.py on first use.
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Final Cut Pro"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == wanted else { continue }
    let b = w[kCGWindowBounds as String] as! [String: Any]
    let name = w[kCGWindowName as String] as? String ?? ""
    print(w[kCGWindowNumber as String]!, name, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
