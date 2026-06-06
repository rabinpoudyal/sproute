import Foundation
import SproutEngine

// The app and helper pin each other against the self-signed "Sprout Dev" leaf
// (see SproutSigning). Unsigned dev builds fail closed: the placeholder hash
// rejects all callers until `make certs` + `make app` produce a real signature.
let appRequirement = SproutSigning.appRequirement

let delegate = HelperService(appRequirement: appRequirement)
let listener = NSXPCListener(machServiceName: sproutHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// launchd owns the lifetime; park the main thread.
RunLoop.current.run()
