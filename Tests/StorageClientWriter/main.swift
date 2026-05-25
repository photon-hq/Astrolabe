import AstrolabeUtils
import Foundation

@main
struct StorageClientWriter {
    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let count = Int(CommandLine.arguments[3])
        else {
            throw WriterError.invalidArguments
        }

        let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let prefix = CommandLine.arguments[2]
        let client = StorageClient(fileURL: fileURL)

        for index in 0..<count {
            try client.write("gitgate/\(prefix)-\(index)", value: "checksum-\(prefix)-\(index)")
        }
    }
}

enum WriterError: Error {
    case invalidArguments
}
