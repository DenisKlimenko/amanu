# Amanu agent instructions

## Windows testing

- The user has connected a Windows computer to Codex for Amanu development and testing. Treat it as an available testing environment, but confirm that the host is online and the project is accessible before relying on it.
- For changes to the Windows app, run the relevant build and tests on Windows. When behavior depends on the Windows graphical interface, launch the app there and verify the actual flow with Computer Use when available.
- Mac-only checks or CI results do not establish that the Windows app works. Report which checks ran on the Windows host and any checks that could not run.
- If the current chat runs on another host, use the connected Windows host or arrange a handoff of the chat to it before Windows-specific validation. If the host is unavailable, state the blocker instead of claiming Windows verification.
