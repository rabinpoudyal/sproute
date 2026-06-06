import Foundation
import SproutEngine

// Placeholder app requirement until Plan 2b-3 generates the real
// identifier + leaf-cert SHA-256 at sign time. The literal below never matches
// a real signature, so an unsigned dev build rejects all callers until 2b-3
// wires the generated constant in.
let appRequirement = "identifier \"com.sprout.app.PLACEHOLDER\""

let delegate = HelperService(appRequirement: appRequirement)
let listener = NSXPCListener(machServiceName: sproutHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// launchd owns the lifetime; park the main thread.
RunLoop.current.run()
