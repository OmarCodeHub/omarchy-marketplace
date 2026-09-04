## What this changes

<!-- And why. The diff already says what; the description should say why. -->

## How it was verified

<!-- Tick what you ran. All four should pass before review. -->

- [ ] `node test-model.js`
- [ ] `qmllint -I /usr/share/omarchy/shell *.qml` (silent)
- [ ] `omarchy plugin validate .`
- [ ] `bash -n bin/*`
- [ ] Restarted the shell and exercised the change by hand

## Anything not covered

<!-- What you could not test, and why. This is more useful than leaving it blank. -->

---

- [ ] If this touches `bin/`, it still executes no string that came from the network
- [ ] No AI or assistant attribution in the commits
