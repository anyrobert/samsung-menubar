# Samsung-menubar: setup guide for Claude

This is a native macOS menu bar app that controls a Samsung Tizen TV. When a user asks you to set it up, follow these steps in order. Ask the user for anything you cannot find yourself. Do not guess an IP address, MAC address, or TV model.

## 1. Check the Mac

- Confirm macOS 14 or later: `sw_vers -productVersion`.
- Confirm Swift 5.9 or later: `swift --version`. If Swift is missing, tell the user to run `xcode-select --install`.

## 2. Build and check

```sh
bash scripts/build.sh
"dist/Samsung-menubar.app/Contents/MacOS/SamsungMenubar" --self-check
python3 scripts/privacy-check.py
```

Both checks should pass. Do not commit the `dist/` folder.

## 3. Reaching the TV

Terminal sessions are often blocked from the local network by macOS Local Network privacy, so `ping` or `curl` to the TV can fail even when the TV is fine. The app gets its own permission when started with `open`. To test against a TV, run diagnostics through `open` and read the report:

```sh
open -n dist/Samsung-menubar.app --args --diagnose --host TV_IP --trust-new-tv --report /tmp/samsung-diag.json
cat /tmp/samsung-diag.json.log
```

The user must approve the certificate prompt on the Mac and choose Allow on the TV. You cannot do those steps for them. Do not retry pairing in a tight loop; the TV prompt lasts about 30 seconds.

## 4. Compatibility

The only tested model is the **Samsung QN55Q60R** (2019). Any other model is unverified; say so and ask whether the user wants to try anyway.

## Rules while setting up

- Never write the user's IP address, MAC address, serial number, or token into a tracked file. Keep them in the app's settings or in `.local/`, which is ignored by git.
- Never commit or push without the user's explicit approval.
- If something fails, report the exact error and what you ruled out.
