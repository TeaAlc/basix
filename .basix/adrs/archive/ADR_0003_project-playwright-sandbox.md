Status: Superseded by ADR 0004
Context: Projects need optional local-browser permissions without changing global installs.
Decision: Project installer owns marked Playwright settings; TTY defaults No, automation must choose --playwright or --no-playwright. Warn that settings require a new Codex session and allow every loopback port.
Consequences: Existing foreign TOML is preserved or rejected; no per-port restriction is promised.
