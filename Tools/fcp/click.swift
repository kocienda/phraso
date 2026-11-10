// click: post mouse events at screen coordinates (points), for driving an app that
// has no scripting interface. Built by tools/fcp.py on first use.
//
//   click move X Y          click X Y          click double X Y
//   click right X Y         click drag X1 Y1 X2 Y2
import CoreGraphics
import Foundation

func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { print("usage: click [move|double|right|drag] X Y [X2 Y2]"); exit(2) }
var mode = "click"
if ["move", "double", "right", "drag"].contains(args[0]) { mode = args.removeFirst() }
let nums = args.compactMap(Double.init)
guard nums.count >= 2 else { print("need coordinates"); exit(2) }
let p = CGPoint(x: nums[0], y: nums[1])
post(.mouseMoved, p)
usleep(80_000)
switch mode {
case "move":
    break
case "right":
    post(.rightMouseDown, p, button: .right); usleep(60_000); post(.rightMouseUp, p, button: .right)
case "double":
    post(.leftMouseDown, p); usleep(50_000); post(.leftMouseUp, p)
    usleep(80_000)
    post(.leftMouseDown, p, clicks: 2); usleep(50_000); post(.leftMouseUp, p, clicks: 2)
case "drag":
    guard nums.count >= 4 else { print("drag needs X1 Y1 X2 Y2"); exit(2) }
    let q = CGPoint(x: nums[2], y: nums[3])
    post(.leftMouseDown, p); usleep(120_000)
    let steps = 12
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
        usleep(25_000)
    }
    post(.leftMouseUp, q)
default:
    post(.leftMouseDown, p); usleep(60_000); post(.leftMouseUp, p)
}
