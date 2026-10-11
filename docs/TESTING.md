# Manual test checklist

Automated tests (`swift test`) cover the protocol encoding and the safety rules. The checks below need a real account and a real mower. Run them before a release.

Always have someone next to the mower for steps that can make it move.

## Without the mower moving

- [ ] Fresh install: no Keychain item. **Connect my Worx account**, sign in, and the mower appears.
- [ ] The state and battery match the official app. The log shows recent events grouped by day.
- [ ] After 5 minutes without news, the commands lock and say why. Coming back to the window or opening the menu bar panel refreshes the state.
- [ ] The test notification arrives. Notifications are on in System Settings.
- [ ] Menu bar: the panel opens and the icon can be hidden and shown again from Settings.
- [ ] Mac language in French, then in English: the whole interface follows.
- [ ] **Sign out** removes the session. Relaunching asks to connect again.
- [ ] `--check-readonly` (with the app closed) ends with `"status_response_correlated": true` and `"motion_commands_sent": 0`.

## Settings (the mower must not move)

- [ ] Wheel torque +10, mower on its base. The app reports "Setting applied" and the value shown is +10. Set it back afterwards if needed.
- [ ] Delay after rain changed. The new value is shown after the confirmation.
- [ ] Schedule page: the slots match the official app, on the right days and hours.
- [ ] Turn edge cut off on one slot, then change a slot's hours. The official app shows only those changes, and the schedule is still enabled.
- [ ] Add a slot on a free day, then delete it. Deleting a day's first slot moves the second one up.
- [ ] Overlapping two slots of the same day, or ending after midnight, is refused before sending.

## Commands (someone next to the mower)

- [ ] Start, pause, then return to base. Each asks for confirmation, and the mower's answer is shown.
- [ ] Cut the Wi-Fi during a command: the app reports the loss and does not resend.

## Experimental resume

To do only when a real error happens, with the area clear and someone next to the mower. Send one attempt at a time and wait 60 s.

- [ ] Note the error. Use *Try: return to base*, then read the technical log: did the error clear? Did the mower move?
- [ ] If nothing happened, use *Try: start mowing* under the same conditions.
- [ ] Report the error code, the attempt and the result in an issue, without identifiers.
