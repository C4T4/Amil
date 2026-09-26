# Security

Amil runs other programs in a PTY and can read and write the local workspace. A bug here can expose files on the machine of the person using it.

Do not file a public issue for a vulnerability that is not already fixed. Once this repository is on GitHub, use **Security → Report a vulnerability** so the report stays private. Include the version (`CFBundleShortVersionString` in `resources/Info.plist`), the macOS version, and a way to reproduce it.

There is no bug bounty.
