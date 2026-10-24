-- The builder supplies dictionary terms. Every runtime target is passed by Swift.

on adapterVersion()
	return 1
end adapterVersion

on createSession(applicationPath, launchCommand, workingDirectory, timeoutSeconds)
	with timeout of timeoutSeconds seconds
		if application applicationPath is not running then error "原 Ghostty 已退出，请核验旧会话。"
		tell application applicationPath
			activate
			set configuration to new surface configuration
			set command of configuration to launchCommand
			set initial working directory of configuration to workingDirectory
			set wait after command of configuration to false
			if (count of windows) > 0 then
				set createdTab to new tab in (front window) with configuration configuration
				set createdTerminal to focused terminal of createdTab
			else
				set createdWindow to new window with configuration configuration
				set createdTerminal to focused terminal of selected tab of createdWindow
			end if
			return {id of createdTerminal, pid of createdTerminal, tty of createdTerminal}
		end tell
	end timeout
end createSession

on readTerminals(applicationPath, terminalID, timeoutSeconds)
	with timeout of timeoutSeconds seconds
		if application applicationPath is not running then error "原 Ghostty 已退出，请核验旧会话。"
		tell application applicationPath
			if terminalID is "" then
				set targets to every terminal
			else
				set targets to terminals whose id is terminalID
			end if
			set rows to {}
			repeat with currentTerminal in targets
				set end of rows to {id of currentTerminal, pid of currentTerminal, tty of currentTerminal}
			end repeat
			return rows
		end tell
	end timeout
end readTerminals

on focusTerminal(applicationPath, terminalID, timeoutSeconds)
	with timeout of timeoutSeconds seconds
		if application applicationPath is not running then error "原 Ghostty 已退出，请核验旧会话。"
		tell application applicationPath
			set targets to terminals whose id is terminalID
			if (count of targets) is not 1 then error "自建终端已消失。"
			focus (item 1 of targets)
			return (id of focused terminal of selected tab of front window) is terminalID
		end tell
	end timeout
end focusTerminal

on closeFinished(applicationPath, terminalID, timeoutSeconds)
	with timeout of timeoutSeconds seconds
		if application applicationPath is not running then error "原 Ghostty 已退出，请核验旧会话。"
		tell application applicationPath
			set targets to terminals whose id is terminalID
			if (count of targets) is 0 then return true
			if (count of targets) is not 1 then error "专用终端身份不唯一。"
			if (pid of item 1 of targets) is not 0 then return false
			-- Closing the last ordinary window can quit Ghostty, including its Quick Terminal.
			if (count of windows) is 1 then
				set windowTerminals to terminals of item 1 of windows
				if (count of windowTerminals) is 1 then
					if (id of item 1 of windowTerminals) is terminalID then
						repeat with otherTerminal in every terminal
							if (id of otherTerminal) is not terminalID then return false
						end repeat
					end if
				end if
			end if
			close (item 1 of targets)
			return true
		end tell
	end timeout
end closeFinished

