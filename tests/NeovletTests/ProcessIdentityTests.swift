import Darwin
import Testing

@testable import Neovlet

struct ProcessIdentityTests {
  @Test func anExitedProcessIsDeadBeforeItsParentReapsIt() throws {
    var pid: pid_t = 0
    let executable = strdup("/usr/bin/true")!
    defer { free(executable) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
    try #require(posix_spawn(&pid, executable, nil, nil, &arguments, nil) == 0)
    defer { waitpid(pid, nil, 0) }
    var status = siginfo_t()
    try #require(waitid(P_PID, id_t(pid), &status, WEXITED | WNOWAIT) == 0)
    // An unreaped process still accepts kill(0), although proc_pidinfo cannot read it.
    #expect(kill(pid, 0) == 0)
    #expect(try ProcessIdentity.read(pid) == nil)
  }
}
