import Foundation
import SwiftUI

// A helper copy of Phosphene bakes one Wallpaper Engine scene and exits, so a shader
// that hangs the GLSL compiler or the GPU ends this process, never the menu bar app.
if let index = CommandLine.arguments.firstIndex(of: WEBakeHelper.argument), index + 1 < CommandLine.arguments.count {
    exit(WEBakeHelper.run(requestPath: CommandLine.arguments[index + 1]))
}
PhospheneApp.main()
