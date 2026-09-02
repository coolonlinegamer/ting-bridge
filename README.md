# Ting Bridge

Ting Bridge is an unofficial macOS helper that turns the controls on the
[Teenage Engineering EP-2350 Ting](https://teenage.engineering/guides/ep-2350)
microphone into push-to-talk and send controls for the Codex and Claude desktop
apps, and for Claude Code running in iTerm2.

It does not replace the audio connection and it does not install custom
firmware. It reads Ting's controls over USB serial and operates the frontmost
supported app through macOS Accessibility.

> [!IMPORTANT]
> This is a community project. It is not affiliated with or endorsed by
> Teenage Engineering, OpenAI, or Anthropic. App updates can change their user
> interfaces and may require selector updates here.

## What it does

| Ting control | Codex | Claude Home | Claude Code (desktop) | Claude Code (iTerm2) |
| --- | --- | --- | --- | --- |
| Hold and release the main handle | Start and stop dictation | Hold and release dictation | Hold and release dictation | Hold and release dictation |
| Release the green button | Return / submit | Return / submit | Return / submit | Return / submit |

The orange button is intentionally not mapped: it cycles Ting's built-in voice
effects (clean, echo, spring, pixie, robot). Leave it on the clean voice while
dictating — the effects are fun, but speech recognition cannot understand a
pixie.

Safety boundaries are intentionally narrow:

- input is generated only while Codex, Claude, or iTerm2 is frontmost;
- physical clicks are checked against the target application before posting;
- no audio or dictated text is stored by Ting Bridge;
- no network requests are made by Ting Bridge;
- the event log records control transitions and diagnostics, not audio or prompt text.

## Claude Code in iTerm2

Claude Code's terminal voice mode is enabled with `/voice` and defaults to
hold-to-talk on the spacebar. Because a terminal application receives stdin
bytes rather than key events, Claude Code recognises a held spacebar from **key
repeat**. A single synthetic key-down event fires once and never repeats, so it
would only insert one space.

Ting Bridge therefore posts the initial space key-down, then emulates key repeat
with events flagged `keyboardEventAutorepeat` until the handle is released, and
posts the matching key-up on release. Dictation and typing can be mixed in one
prompt, and the green button submits.

Two environment variables tune the emulated repeat, each clamped to 1-5000 ms:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TING_BRIDGE_SPACE_INITIAL_MS` | 30 | Delay before the first repeat |
| `TING_BRIDGE_SPACE_REPEAT_MS` | 15 | Interval between repeats |

The 15 ms default matches one macOS key-repeat unit, which is the fastest rate
real hardware produces. A faster repeat makes Claude Code recognise the hold
sooner, so dictation starts more quickly.

Leave `voice.autoSubmit` off if you want to alternate between typing and
dictating before submitting, which is what the green button is for.

## Hardware setup

### What you need

- a Teenage Engineering EP-2350 Ting;
- a USB-C **data** cable (a charge-only cable will not expose Ting's controls);
- a 3.5 mm-to-USB-C audio **input** adapter. The tested setup uses the
  [Saramonic SR-C2003](https://www.amazon.com/dp/B08DTP7R8M), the adapter from
  Robert Bye's original Ting-dictation setup that inspired this project. Any
  adapter that accepts an analog microphone input works, but many inexpensive
  USB-C headphone dongles are output-only and will not;
- two free USB-C ports on the Mac, or a hub.

### Connections

The setup uses **two connections** between Ting and the Mac:

1. **USB-C data and power:** connect Ting's USB-C port to the Mac. Ting Bridge
   uses the resulting `/dev/cu.usbmodemEPTX*` serial device. USB also powers
   Ting, so batteries are not required.
2. **Audio:** connect Ting's 3.5 mm audio output to the input adapter, then
   connect the adapter to the Mac.

Choose the USB audio adapter under **System Settings > Sound > Input**. Ting's
USB serial connection carries its controls, not the microphone audio used by
Codex or Claude.

> [!NOTE]
> Ting's USB-C port sits under the lower battery lid, so the lid cannot be
> refitted while the cable is attached and the assembled look suffers. Since
> USB power makes batteries unnecessary, a committed desk setup could cut a
> small cable pass-through in the lid. That modification is permanent, cosmetic
> surgery is at your own risk, and it will not improve your warranty.

## Requirements

- macOS 14 or newer
- iTerm2, for the Claude Code terminal mapping
- Swift 6 / Xcode Command Line Tools
- Ting connected over USB-C data
- a separate working audio-input path from Ting to macOS
- OpenSSL with `req -addext` support for the one-time local signing setup

Install the command-line tools if needed:

```bash
xcode-select --install
```

If the signing setup says a compatible OpenSSL is missing, install OpenSSL 3:

```bash
brew install openssl@3
```

## Install

Clone the repository:

```bash
git clone https://github.com/l7073a/ting-bridge.git
cd ting-bridge
```

Create the local signing identity once:

```bash
./scripts/setup-signing-identity.sh
```

This creates a three-year self-signed **leaf** identity named `Ting Bridge
Local Code Signing` in your login Keychain. It is not a certificate authority;
the certificate is trusted only for the macOS `codeSign` policy. The private key
remains in your Keychain. A stable identity is necessary because rebuilding an
ad-hoc-signed Accessibility helper causes macOS to treat it as a different app.

If you already have a suitable Apple Development or other code-signing
identity, skip that script and provide its name when installing:

```bash
TING_BRIDGE_SIGNING_IDENTITY="Apple Development: Your Name (…)" \
  ./scripts/install-app.sh
```

Otherwise install with the local identity:

```bash
./scripts/install-app.sh
```

The installer:

- builds a release executable;
- installs and signs `~/Applications/Ting Bridge.app`;
- installs `~/Library/LaunchAgents/com.bubblymagic.tingbridge.plist`;
- starts the bridge and configures it to start at login.

### Grant Accessibility

On the first signed installation:

1. Open **System Settings > Privacy & Security > Accessibility**.
2. Click **+** and add `~/Applications/Ting Bridge.app`.
3. Turn **Ting Bridge** on.
4. Restart only the helper so it picks up the new permission:

```bash
launchctl kickstart -k "gui/$(id -u)/com.bubblymagic.tingbridge"
```

You should then see these lines in `~/Library/Logs/TingBridge.log`:

```text
Connected to Ting at /dev/cu.usbmodemEPTX…
Ting controls ready
```

## Use

1. Confirm Ting is powered and its audio adapter is selected as the Mac's input.
2. Bring Codex or Claude to the front.
3. Hold the Ting handle while speaking and release it to stop dictation.
4. Release the green button to submit.

Claude Code requires a local workspace. If its first submission opens a folder
selector, choose the folder you want Claude Code to work in. That is expected
Claude behavior, not an attachment click from Ting Bridge. Once a workspace is
selected, the pending prompt continues normally.

## Verify and diagnose

Watch the live event log:

```bash
tail -f ~/Library/Logs/TingBridge.log
```

Check that Ting's serial device exists:

```bash
ls /dev/cu.usbmodemEPTX*
```

Run the no-hardware regression checks for serial selection and control-event
deduplication:

```bash
swift run TingBridge self-test
```

Run an eight-second audio-level probe against the Mac's selected input:

```bash
swift run TingBridge audio-probe 8
```

Dump Claude's current Accessibility tree using the already-authorized signed
binary:

```bash
~/Applications/Ting\ Bridge.app/Contents/MacOS/TingBridge ax-dump
```

`ax-dump` writes diagnostics only to the terminal, never to `TingBridge.log`,
and redacts accessibility value fields. The Claude selectors currently rely on
English accessibility labels such as “Hold to record”; non-English app UI may
need selector updates.

### Common problems

**Nothing happens when a control is pressed**

- Verify the log contains `Ting controls ready`.
- Verify Ting appears at `/dev/cu.usbmodemEPTX*`.
- Confirm Ting Bridge is enabled in Accessibility.
- If Ting's lights are off after reconnecting it, power Ting back on before
  testing.

**Dictation opens but recognition is poor**

- Check **Sound > Input** and its input level.
- Confirm the analog-to-USB adapter is an input device, not a headphone-output
  adapter.
- Select Ting's clean/no-effect sound before dictating.

**Claude Code opens a folder selector**

- Select a local workspace folder. Code mode cannot begin a session without
  one.

**Accessibility breaks after rebuilding**

- Do not copy an ad-hoc-signed binary into the app bundle. Always rebuild with
  `./scripts/install-app.sh` so the designated code requirement stays stable.

## Rebuild after changes

Use the installer for every local rebuild:

```bash
./scripts/install-app.sh
```

The same signing identity is reused, so the existing Accessibility grant should
survive the update.

## Uninstall

```bash
./scripts/uninstall-app.sh
```

The uninstaller stops and removes Ting Bridge, its LaunchAgent, logs, and its
Accessibility grant. It intentionally leaves the local signing identity in the
login Keychain so reinstalling remains stable. The script prints the optional
Keychain command that deletes the identity and its local trust setting if you
also want to remove both.

## How it works

Ting Bridge is a small Swift executable. It starts a temporary polling loop in
Ting's MicroPython REPL over USB serial and normalizes handle and green-button
state changes. No firmware is flashed or persisted.

The Swift process then:

1. verifies that Codex or Claude is frontmost;
2. locates the relevant dictation control through the Accessibility tree;
3. hit-tests any physical click against the expected application;
4. maps control transitions to app-specific mouse or keyboard events;
5. releases held input during disconnects and shutdown.

## License

[MIT](LICENSE)
