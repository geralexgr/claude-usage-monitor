# Claude Usage Monitor

A native macOS menu bar app that shows your Claude Pro usage in real time.
Reads directly from the claude.ai API every 10 seconds. No browser window, no external dependencies.

---

## Requirements

- macOS 11 or later
- Xcode Command Line Tools (free, from Apple)
- A claude.ai account with a Pro plan

Install the command line tools if you haven't already (one-time):

```bash
xcode-select --install
```

---

## Build

```bash
swiftc ClaudeUsage.swift -o ClaudeUsage -framework Cocoa
```

---

## First-time setup — session cookie

The app authenticates using your claude.ai session cookie.

### Step 1 — Get your sessionKey cookie

1. Open **https://claude.ai** in your browser (logged in)
2. Press `Option + Cmd + I` to open DevTools
3. Go to the **Application** tab → **Cookies** → `https://claude.ai`
   *(Firefox: Storage tab → Cookies)*
4. Find the row named **`sessionKey`**
5. Copy its entire **Value** (a long string)

### Step 2 — Paste it into the config file

Run the app once to create the config file automatically:

```bash
./ClaudeUsage
```

Then open the config file in any text editor:

```bash
open ~/.claude_usage.conf
```

Replace `PASTE_YOUR_COOKIE_HERE` with your copied value:

```
sessionKey=eyJhbGci...your full value here...
```

Save the file. The app picks it up on the next 10-second refresh — no restart needed.

---

## Menu bar

| Icon | Meaning |
|---|---|
| 🟢 X% | Under 50% of 5-hour window used |
| 🟡 X% | 50–79% used |
| 🔴 X% | 80%+ used |
| ⚪️ … | Loading |
| 🔑 | Cookie expired — update config file |

The dropdown shows both your **5-hour** and **7-day** usage windows with reset countdowns.

---

## Run as a background service (survives terminal close and reboots)

### Step 1 — Find your binary's full path

```bash
realpath ./ClaudeUsage
```

Copy the output — you'll need it in the next step.

### Step 2 — Create the launch agent

Replace `/YOUR/FULL/PATH/ClaudeUsage` with the path from Step 1:

```bash
cat > ~/Library/LaunchAgents/com.claude.usagemonitor.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.usagemonitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/YOUR/FULL/PATH/ClaudeUsage</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude_usage.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude_usage.log</string>
</dict>
</plist>
EOF
```

### Step 3 — Start the service

```bash
launchctl load ~/Library/LaunchAgents/com.claude.usagemonitor.plist
```

The menu bar icon will appear immediately. The service starts automatically on every login.
`KeepAlive: true` means macOS will restart it automatically if it ever crashes.

---

## Shell aliases (zshrc)

Add these to `~/.zshrc` for quick control from the terminal:

```bash
# Claude Usage Monitor
alias claudemonitor-start="launchctl load ~/Library/LaunchAgents/com.claude.usagemonitor.plist"
alias claudemonitor-stop="launchctl unload ~/Library/LaunchAgents/com.claude.usagemonitor.plist"
alias claudemonitor-restart="launchctl unload ~/Library/LaunchAgents/com.claude.usagemonitor.plist && launchctl load ~/Library/LaunchAgents/com.claude.usagemonitor.plist"
alias claudemonitor-logs="tail -f /tmp/claude_usage.log"
alias claudemonitor-status="launchctl list | grep claude"
```

Apply immediately:

```bash
source ~/.zshrc
```

Then use:

```bash
claudemonitor-start    # start the service
claudemonitor-stop     # stop it
claudemonitor-restart  # restart it
claudemonitor-logs     # watch live logs
claudemonitor-status   # check if it's running
```

---

## Sharing with others

Nothing is hardcoded. Anyone can use this app — they just need their own session cookie.

1. Give them `ClaudeUsage.swift`
2. They compile it:
   ```bash
   swiftc ClaudeUsage.swift -o ClaudeUsage -framework Cocoa
   ```
3. They run it once, click **📝 Open Config File** in the menu bar, paste their own `sessionKey` and save

The org ID and all usage data are fetched dynamically from their own account.

---

## Files created by the app

| File | Purpose |
|---|---|
| `~/.claude_usage.conf` | Your session cookie (edit this to update credentials) |
| `~/Library/LaunchAgents/com.claude.usagemonitor.plist` | macOS service definition |
| `/tmp/claude_usage.log` | App logs (only when running as a service) |
