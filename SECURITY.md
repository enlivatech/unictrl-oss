# Security

Unictrl carries keystrokes over the network, so security reports are taken seriously.

Please report a vulnerability privately by email to **support@enliva.org** rather than in a public
issue. Include the version or commit, what you found and how to reproduce it. You will get a reply as
soon as possible; this is a small project, so please allow a few days.

The design is described in `docs/PROTOCOL.md` (pairing, key derivation, frame encryption). Known
limits: Unictrl assumes a trusted LAN, pairing keys are stored unencrypted in the local settings
file, and anyone who can run code as your user can read them.

Unictrl 传输的是按键，安全问题请发邮件到 support@enliva.org 私下报告，不要开公开 issue。
