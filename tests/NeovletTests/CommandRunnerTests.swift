import Foundation
import Testing

@testable import Neovlet

@Test func commandPreservesLiteralArguments() async throws {
  let literal = "中文 '$(literal) \\ \n end"
  let result = try await CommandRunner().run(["/usr/bin/printf", "%s", literal])
  #expect(result.status == 0)
  #expect(result.output == literal)
  #expect(result.error.isEmpty)
}

@Test func ghosttyLaunchQuotingPreservesSpecialPaths() async throws {
  let literal = "中文 '$(touch nope); \\ \n end"
  let command = "exec /usr/bin/printf %s " + CommandRunner.quote(literal)
  let result = try await CommandRunner().run(["/bin/sh", "-c", command])
  #expect(result.output == literal)
}

@Test func timeoutReapsAnUnresponsiveChild() async throws {
  let start = ProcessInfo.processInfo.systemUptime
  await #expect(throws: AppFailure.self) {
    _ = try await CommandRunner().run(
      ["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 5"], timeout: 0.1)
  }
  #expect(ProcessInfo.processInfo.systemUptime - start < 2)
}

@Test func largeSimultaneousOutputDoesNotDeadlock() async throws {
  let result = try await CommandRunner().run([
    "/usr/bin/awk",
    "BEGIN { for(i=0;i<20000;i++){print \"out\"; print \"err\" > \"/dev/stderr\"} exit 7 }",
  ])
  #expect(result.status == 7)
  #expect(result.output == String(repeating: "out\n", count: 20000))
  #expect(result.error == String(repeating: "err\n", count: 20000))
}
