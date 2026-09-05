# Claude Code Phone Gateway (Windows)

Keep `claude remote-control` running on your Windows PC so the **Claude mobile app can start
new Claude Code sessions on your own machine**, with your files, tools and settings, and keep
working after reboots and network drops.

Pure Windows PowerShell 5.1. Nothing to install: no Python, no Node, no admin rights,
no services, no scheduled tasks.

## Why this exists

Claude Desktop already mirrors sessions you open on the PC to your phone. The other direction
is the gap: **a new session started from the phone runs in Anthropic's cloud by default**,
where it cannot see your local files. Claude Code's answer is server mode,
`claude remote-control`, which makes your PC appear under *Devices* in the app. Two things
make it a poor daemon on its own:

- it exits by design after roughly 10 minutes without network, and
- nothing starts it after a reboot.

This repo is a small supervisor around it, plus a `doctor` that tells you exactly why it
cannot run, and an installer that wires it into your Startup folder.

## Requirements

- Windows 10 or 11.
- [Claude Code](https://code.claude.com/docs/en/setup) 2.1.51 or newer. Any install method works:
  the native installer, npm, or the copy bundled inside Claude Desktop (auto-detected in that order).
- A **claude.ai subscription login** (Pro, Max, or Team/Enterprise with Remote Control enabled by
  an admin). Remote Control does not work with API keys.
- The Claude app on your phone, signed into the same account.

## Install

```powershell
git clone https://github.com/<you>/claude-code-phone-gateway.git
cd claude-code-phone-gateway
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Name "My PC"
```

`doctor.ps1` checks Windows, PowerShell, the `claude` binary and version, your login, interfering
environment variables, the work folder, and then runs a **live probe**: it starts the server once,
waits for the `https://claude.ai/code?environment=...` line, and stops it. Every check prints
`PASS`, `WARN` or `FAIL` with a one-line fix.

`install.ps1` does exactly four things:

1. marks the work folder as trusted in `~/.claude.json` (a backup is written first);
2. runs the same live probe and **refuses to install if it fails**;
3. writes `start-gateway.cmd` and a Startup shortcut that launches it with no visible window;
4. starts the gateway now and waits for the `connected:` line.

Expected tail of the install output:

```
[2/4] live probe: starting claude remote-control once...
OK  remote-control server connected.
    environment: https://claude.ai/code?environment=env_...
[3/4] startup entry created: C:\Users\you\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Claude Code Phone Gateway.lnk
[4/4] gateway running and connected: https://claude.ai/code?environment=env_...
```

### Options

| Parameter | Meaning | Default |
| --- | --- | --- |
| `-Name` | Session name shown in the Claude app | computer name |
| `-WorkDir` | Folder new phone sessions start in. **Not** your profile root; Claude refuses to serve it | the repo folder |
| `-ClaudePath` | Explicit path to `claude.exe` / `claude.cmd` | auto-detect |
| `-NoStart` | Install without starting now | off |
| `-Uninstall` | Remove the Startup entry and stop the gateway | |

## Use it from your phone

1. Open the Claude app, tap **Code**.
2. Under **Devices**, pick this computer (it is online when the gateway is connected).
3. Choose the work folder you installed with, then **New session**.

The session runs on your PC. Sessions you open on the PC keep appearing on the phone as before;
this gateway only adds the phone-to-PC direction. The app's wording may change between versions;
the rule of thumb is: pick your **computer**, not a GitHub repository, or you get a cloud session.

## Verify and logs

Everything lives in `<WorkDir>\logs\`:

| File | What it is |
| --- | --- |
| `gateway.log` | Supervisor events: `server started`, `connected: <url>`, `server exited rc=...`, `restarting in Ns` |
| `server.log` | The server's own output (rotated at 2 MB to `server.log.1`). This is where the real error is when something silently fails |
| `gateway.lock` | PID of the running supervisor (single-instance guard) |
| `ALERT-gateway.txt` | Written when the server dies quickly three times in a row, and again when it recovers |

Quick health check:

```powershell
Get-Content .\logs\gateway.log -Tail 5
```

A healthy gateway shows a `connected:` line after each start. Restarts every few minutes are
normal after a network drop; the server exits on its own and the supervisor brings it back.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Stops the gateway and removes the Startup entry. Logs and the trust flag in `~/.claude.json`
are left in place.

## Troubleshooting: the failures that are silent by default

These are the ones that cost real time before this repo handled them.

| Symptom in `logs\server.log` or the probe | Cause | Fix |
| --- | --- | --- |
| `Error: Workspace not trusted. Please run claude in <dir> first` | The work folder is not trusted | `install.ps1` seeds the flag. Manual alternative: run `claude` once inside the folder and accept the prompt |
| `Remote Control requires claude.ai subscription auth. ANTHROPIC_API_KEY is set` | An inherited API key makes claude pick API-key auth | The gateway strips `ANTHROPIC_*`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` for the server process. If you launch the server yourself, unset them first |
| Server exits with `rc=1` every 30-600 s, `gateway.log` only says `restarting` | Any auth or trust problem above | Read `logs\server.log`; the alert file names the last line |
| `home-directory trust is never saved` | `-WorkDir` is your profile root | Use a subfolder |
| Server exits about 10 minutes after the PC loses network | By design | The supervisor restarts it with backoff (30 s doubling to 10 min) |
| A modal error box appears while Windows shuts down | `taskkill` cannot run during shutdown | Handled: the gateway skips the kill when Windows reports shutdown |
| Extra idle entries named after your PC pile up in the phone list | Each server (re)start pre-creates one session | Harmless; swipe them away |

## Optional: share memory with your main project

Claude Code's auto-memory is per project folder. Sessions started from the phone run in the
work folder, so they start with an empty memory. If you want them to share the memory of the
project you normally use (for Claude Desktop users that is usually your profile folder):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\link-memory.ps1 -ShareFrom C:\Users\you
```

It replaces the work folder's memory directory with a junction to the other one: same files,
two entry points, no copies. It refuses to run if the work folder already has memory files.
`-Remove` undoes the link without touching any file.

## How it works

- The server is started through `cmd.exe /c "... 2>&1"` with `CreateNoWindow`, so it runs both
  `claude.exe` and the npm `claude.cmd` shim, never flashes a console, and one reader drains a
  single merged stream (no stderr deadlock).
- stdin is closed, so the TUI never waits for a keypress.
- A lock file with the supervisor's PID prevents two gateways for the same folder; the PID is
  verified against the process command line, so a reused PID does not fool it.
- Exit within 120 s counts as a failure: backoff doubles from 30 s to 10 min, and after three
  failures in a row `ALERT-gateway.txt` is written with the server's last output line.
- Windows shutdown is detected with `GetSystemMetrics(SM_SHUTTINGDOWN)`; the gateway then leaves
  the child to the OS instead of calling `taskkill`, which would hang the shutdown screen.

## Related projects

Two other repos keep `claude remote-control` alive on Windows with a scheduled task:
[claude-remote-control-keepalive](https://github.com/curran-gehring/claude-remote-control-keepalive)
and [claude-rc-service](https://github.com/jozefkun/claude-rc-service). This one differs in
needing no scheduled task, service, admin rights or feature-flag edits, and in adding the
doctor, the API-key strip, the alert file and the shutdown guard. Anthropic may ship an
always-on option natively at some point; when that happens, uninstall this and use theirs.

## License

MIT.

---

## 中文摘要

**做什麼**：讓 `claude remote-control` 伺服器在 Windows 上一直活著，手機的 Claude App 就能在
你自己的電腦上「開新的」Claude Code 對話，用得到本機檔案；重開機、斷網後會自己回來。

**為什麼需要**：桌面版開的對話會自動出現在手機上，但手機主動開的新對話預設跑在雲端、碰不到本機。
官方的伺服器模式解決這件事，只是它斷網約 10 分鐘會自己退出、開機也不會自己啟動。

**怎麼裝**：三個指令，見上方 Install。純 PowerShell，不用裝 Python 或 Node，不需要管理員權限。
`doctor.ps1` 會逐項告訴你哪裡不符合、怎麼修；`install.ps1` 先實測連得上才安裝。

**手機端**：Claude App → Code → Devices 選這台電腦 → 選安裝時的資料夾 → New session。
記得選「電腦」而不是 GitHub 專案，選錯就是雲端對話。

**常見的靜默失敗**：資料夾未信任、環境變數有 `ANTHROPIC_API_KEY`、用 API 金鑰而非訂閱登入、
工作目錄是家目錄。細節看上方 Troubleshooting 表。
