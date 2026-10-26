import Foundation
import ShotsMedia

let status = await ShotsCommandLine.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
