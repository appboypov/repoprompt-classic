import Foundation
import Darwin
import Darwin.POSIX.fcntl

struct SpawnedProcess: @unchecked Sendable {
	let pid: pid_t
	let stdin: FileHandle?
	let stdinDescriptor: Int32?
	let stdout: FileHandle
	let stderr: FileHandle
}

enum ProcessLauncherError: Error {
	case pipeCreationFailed(String)
	case changeDirectoryFailed(path: String, errno: Int32)
	case spawnAttributesFailed(operation: String, errno: Int32)
	case spawnFailed(errno: Int32)
}

enum ProcessLauncher {
	static func spawn(
		command: String,
		arguments: [String],
		environment: [String: String],
		workingDirectory: String?
	) throws -> SpawnedProcess {
		var stdinPipe: [Int32] = [-1, -1]
		var stdoutPipe: [Int32] = [-1, -1]
		var stderrPipe: [Int32] = [-1, -1]

		func setCloexec(_ fd: Int32) {
			let flags = fcntl(fd, F_GETFD)
			if flags != -1 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
		}

		func closePipe(_ pipe: inout [Int32]) {
			if pipe[0] != -1 { close(pipe[0]) }
			if pipe[1] != -1 { close(pipe[1]) }
			pipe = [-1, -1]
		}

		guard pipe(&stdinPipe) == 0 else {
			throw ProcessLauncherError.pipeCreationFailed("stdin")
		}
		guard pipe(&stdoutPipe) == 0 else {
			closePipe(&stdinPipe)
			throw ProcessLauncherError.pipeCreationFailed("stdout")
		}
		guard pipe(&stderrPipe) == 0 else {
			closePipe(&stdinPipe)
			closePipe(&stdoutPipe)
			throw ProcessLauncherError.pipeCreationFailed("stderr")
		}

		// Prevent leakage of our ends into any grandchildren.
		setCloexec(stdinPipe[0]); setCloexec(stdinPipe[1])
		setCloexec(stdoutPipe[0]); setCloexec(stdoutPipe[1])
		setCloexec(stderrPipe[0]); setCloexec(stderrPipe[1])
		_ = FDWriteSupport.configureNoSigPipe(fd: stdinPipe[1])
		
		var fileActions: posix_spawn_file_actions_t? = nil
		posix_spawn_file_actions_init(&fileActions)
		defer { posix_spawn_file_actions_destroy(&fileActions) }
		
		posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
		posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
		posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1])
		posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
		posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
		
		if let workingDirectory {
			let result = workingDirectory.withCString { pointer -> Int32 in
		#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
				return posix_spawn_file_actions_addchdir_np(&fileActions, pointer)
		#else
				return 0
		#endif
			}
			if result != 0 {
				closePipe(&stdinPipe)
				closePipe(&stdoutPipe)
				closePipe(&stderrPipe)
				throw ProcessLauncherError.changeDirectoryFailed(path: workingDirectory, errno: result)
			}
		}
		
		var attributes: posix_spawnattr_t? = nil
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }

		// Parent-side write paths use no-SIGPIPE hardening; restore the default SIGPIPE
		// disposition in spawned children so CLI/tool processes keep normal pipe semantics.
		var defaultSignals = sigset_t()
		sigemptyset(&defaultSignals)
		sigaddset(&defaultSignals, SIGPIPE)

		var spawnFlags: Int16 = 0
		let getFlagsResult = posix_spawnattr_getflags(&attributes, &spawnFlags)
		if getFlagsResult != 0 {
			closePipe(&stdinPipe)
			closePipe(&stdoutPipe)
			closePipe(&stderrPipe)
			throw ProcessLauncherError.spawnAttributesFailed(operation: "getflags", errno: getFlagsResult)
		}

		let setSigDefaultResult = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
		if setSigDefaultResult != 0 {
			closePipe(&stdinPipe)
			closePipe(&stdoutPipe)
			closePipe(&stderrPipe)
			throw ProcessLauncherError.spawnAttributesFailed(operation: "setsigdefault", errno: setSigDefaultResult)
		}

		let setFlagsResult = posix_spawnattr_setflags(&attributes, spawnFlags | Int16(POSIX_SPAWN_SETSIGDEF))
		if setFlagsResult != 0 {
			closePipe(&stdinPipe)
			closePipe(&stdoutPipe)
			closePipe(&stderrPipe)
			throw ProcessLauncherError.spawnAttributesFailed(operation: "setflags", errno: setFlagsResult)
		}
		
		var argv: [UnsafeMutablePointer<CChar>?] = []
		argv.reserveCapacity(arguments.count + 2)
		argv.append(strdup(command))
		for argument in arguments {
			argv.append(strdup(argument))
		}
		argv.append(nil)
		defer {
			for pointer in argv where pointer != nil {
				free(pointer)
			}
		}
		
		var envp: [UnsafeMutablePointer<CChar>?] = []
		envp.reserveCapacity(environment.count + 1)
		for (key, value) in environment {
			envp.append(strdup("\(key)=\(value)"))
		}
		envp.append(nil)
		defer {
			for pointer in envp where pointer != nil {
				free(pointer)
			}
		}
		
		var pid: pid_t = 0
		let spawnResult = posix_spawnp(
			&pid,
			command,
			&fileActions,
			&attributes,
			argv,
			envp
		)
		
		if spawnResult != 0 {
			closePipe(&stdinPipe)
			closePipe(&stdoutPipe)
			closePipe(&stderrPipe)
			throw ProcessLauncherError.spawnFailed(errno: spawnResult)
		}
		
		close(stdinPipe[0])
		close(stdoutPipe[1])
		close(stderrPipe[1])
		
		let stdinHandle = FileHandle(fileDescriptor: stdinPipe[1], closeOnDealloc: true)
		let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
		let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
		
		return SpawnedProcess(
			pid: pid,
			stdin: stdinHandle,
			stdinDescriptor: stdinPipe[1],
			stdout: stdoutHandle,
			stderr: stderrHandle
		)
	}
}
