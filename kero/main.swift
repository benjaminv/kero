import SwiftUI

// The bundle ships an `ssh` symlink to this binary beside it in
// Contents/MacOS, and Kero prepends that directory to every terminal's PATH.
// Invoked under that name the process is an ssh front end: it must reach
// neither the CLI nor the app, or a typed `ssh` would open a project.
if KeroSSHPassthrough.isInvokedAsSSH {
    KeroSSHPassthrough.main()
}

if KeroCommandLine.shouldRun {
    KeroCommandLine.main()
}

keroApp.main()
