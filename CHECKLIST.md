# Call checklist: ASUS Zenbook S 16 (UM5606G)

Everything up to "Send for engraving" must happen inside the return window.

## Before the call (helper)
1. Make sure the repo is public (switch it back to private after the call).
2. Ask the owner to have ready: the charger, a USB-A stick or mouse, any USB-C device, headphones, and a phone on a video call (so you can see the keyboard and hinge).

## 1. Connect
1. You: open Quick Assist, choose **Help someone**, sign in with your Microsoft account, and read the code to the owner.
   Owner: press **Ctrl + Win + Q** (or Start, type "Quick Assist") and type the code under **Get help**.
2. Owner enters the code and allows **full control**.
3. Open Start, type `PowerShell`, choose **Run as administrator**. The owner clicks **Yes** (your view pauses until they do). Use this one window for everything below.

## 2. Get the tool and audit
1. In the admin window:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   $d = "$env:TEMP\InstallMedia"
   Invoke-WebRequest https://github.com/nakedblast/InstallMedia/archive/refs/heads/main.zip -OutFile "$d.zip" -UseBasicParsing
   Expand-Archive "$d.zip" $d -Force
   cd "$d\InstallMedia-main"
   .\Setup.ps1 -Profile zenbook-s16-um5606g -AuditOnly
   ```
   After a reboot: reopen the admin window, run the first line, then `cd "$env:TEMP\InstallMedia\InstallMedia-main"`.
2. Read the summary: any **FAIL** (model, CPU, RAM, disk, edition) means stop and contact the seller. Check that activation is OK, the serial matches the box and invoice, the battery cycle count is near 0 and health is ~100%, and no devices show errors.

## 3. Hardware checks (owner's hands, you watching)
- [ ] **Screen**: `.\tools\ScreenTest.ps1` (full-screen white, black, red, green, blue, mid grey, dark grey; click or Space for next, Esc to quit). The owner judges, not you: Quick Assist compresses the picture. They look for dead or stuck pixels, bright specks on black, tint blotches or banding on the greys; repeat the greys at low brightness.
- [ ] **Touchscreen**: draw lines across the whole screen in Paint, including corners and edges.
- [ ] **Keyboard**: in Notepad, type every row with and without Shift, then test Fn keys (brightness, volume, mute, keyboard backlight), arrows, Copilot key, Delete/Home/End. Every key matters: these are the caps that get engraved.
- [ ] **Touchpad**: click both sides, tap, two-finger scroll, three-finger swipe; edges respond.
- [ ] **Ports**: charger in each USB-C port (charges on both), USB-A device, USB-C device, HDMI and SD card if present, headphone jack.
- [ ] **Webcam**: Camera app; set up **Windows Hello face** (tests the IR camera).
- [ ] **Microphone**: Settings > System > Sound > Input, test level while the owner talks.
- [ ] **Speakers**: Settings > System > Sound > Output > Test: both channels, no rattle at high volume.
- [ ] **Wi-Fi and Bluetooth**: browsing works; pair the owner's phone or headphones.
- [ ] **Body**: hinge opens smoothly, holds position, no creak; lid and keyboard deck flex; no dents, scratches, gaps or marks on the white finish; no pressure marks on the screen.
- [ ] **Charger**: charges, no buzzing or excessive heat.
- [ ] Optional **stress test** (on the charger): `.\Setup.ps1 -Profile zenbook-s16-um5606g -Only Stress -StressMinutes 10`. Ask about fan noise and heat over the keyboard; check the result summary.

## 4. Updates
1. Settings > Windows Update: install everything, including **Advanced options > Optional updates** (drivers). Reboot and repeat until nothing is left. Each reboot drops Quick Assist: the owner reconnects with a new code, and you reopen the admin window.
2. **MyASUS** > System Update: install BIOS/firmware and driver updates, laptop on the charger.

## 5. MyASUS settings
- [ ] Register the product (warranty) with the owner's email.
- [ ] Customization > **OLED Care**: Pixel Refresh on, Pixel Shift on, taskbar transparency/auto-hide as the owner prefers.
- [ ] Customization > Battery: **Battery Care Mode** (charge limit ~80%) if the laptop mostly stays plugged in. Ask the owner.
- [ ] **Presence sensing** (camera-based): Settings > System > Power & battery > Screen, sleep & hibernate timeouts, or Settings > Privacy & security > Presence sensing (on ASUS it may also sit in MyASUS as Adaptive Dimming / Adaptive Lock).
  - Turn on **Turn off my screen when I leave**: the best OLED protection, since the screen goes dark within seconds of the owner walking away instead of waiting for the timer.
  - **Wake when I approach** and **Dim when I look away**: owner's choice. Dimming can annoy someone who reads a paper document beside the laptop.
  - Test it: owner walks away; the screen should go off in well under a minute.

## 6. Run the setup profile
1. Ask the owner: **dark mode?** **auto-hide taskbar?** (both reduce OLED wear; auto-hide changes how the taskbar behaves).
2. Run, adding the chosen options:
   ```powershell
   .\Setup.ps1 -Profile zenbook-s16-um5606g                      # full profile
   .\Setup.ps1 -Profile zenbook-s16-um5606g -Enable DarkMode,AutoHideTaskbar   # with options
   ```
3. Go through the bloat list together; enter only the numbers the owner agrees to remove.
4. Reboot, then verify:
   - [ ] Start, type `weather`: no web results.
   - [ ] **Win + Space** switches ENG / RUS; typing `'` and `"` in Notepad produces them immediately (no accent waiting).
   - [ ] Screen turns off after the set time on battery.
5. Owner changes their mind on an option later: `.\Setup.ps1 -Profile zenbook-s16-um5606g -Only Display -Enable DarkMode` (or `-Revert -Only Display`).
6. Undo, if ever needed: `.\Setup.ps1 -Profile zenbook-s16-um5606g -Revert` (or `-Revert -Only Search` etc.). The change log lives in `C:\ProgramData\InstallMedia`, so this works from a fresh download too. A restore point "InstallMedia before ..." also exists.

## 7. Owner's preferences
- [ ] Default browser; sign in to the browser if wanted.
- [ ] Office: sign in with the account that holds the Microsoft 365 licence; open Excel once.
- [ ] OneDrive: back up Desktop/Documents or not (owner's choice).
- [ ] Regional formats (Settings > Time & language > Region): date format and decimal separator, which affect Excel.
- [ ] Device encryption recovery key is saved to the Microsoft account (Settings > Privacy & security > Device encryption).
- [ ] Files from the old HP laptop (OneDrive, or a USB stick).
- [ ] Printer, if any.

## 8. Before sending for engraving
- [ ] Photo or PDF of the invoice and the box label (serial) saved somewhere safe (cloud + email to self).
- [ ] Confirm with the shop: standard **Russian ЙЦУКЕН** layout (Windows "Russian"), not phonetic.
- [ ] Delete the downloaded tool: `Remove-Item "$env:TEMP\InstallMedia", "$env:TEMP\InstallMedia.zip" -Recurse -Force` (the Desktop report and the change log stay).
- [ ] Switch the GitHub repo back to private.
- [ ] Owner signs out or locks the laptop; the shop needs no password.
- [ ] After engraving: quick look that letters match what Windows types for a few keys (Ф = A, Я = Z, Ж = ;).
