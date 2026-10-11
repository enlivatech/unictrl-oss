# Security

Unictrl carries keystrokes over the network, so security reports are taken seriously.

Please report a vulnerability privately, not in a public issue: use GitHub's
[private vulnerability reporting](https://github.com/enlivatech/unictrl-oss/security/advisories/new), or
email **support@enliva.org**. Include the version or commit, what you found and how to reproduce it. You will get a reply as
soon as possible; this is a small project, so please allow a few days.

The design is described in `docs/PROTOCOL.md` (pairing, key derivation, frame encryption). Known
limits: Unictrl assumes a trusted LAN, pairing keys are stored unencrypted in the local settings
file, and anyone who can run code as your user can read them.

Unictrl 传输的是按键。安全问题请通过 GitHub 的私下报告入口或发邮件到 support@enliva.org 报告，不要开公开 issue。
Unictrl 傳輸的是按鍵。安全性問題請透過 GitHub 的私下回報入口或寄信到 support@enliva.org 回報，不要開公開 issue。
