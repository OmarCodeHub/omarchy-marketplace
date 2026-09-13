# Contributing

Thanks for looking. This is an Omarchy Quattro shell plugin in QML, JavaScript
and bash, with no build step.

## Ground rules

- **`main` is protected.** Work on a branch and open a pull request. Nobody
  pushes to `main` directly.
- **Every change must pass the checks below** before it is reviewed.
- **Nothing in `bin/` may execute a string that came from the network.** See
  [Security](#security-non-negotiables).
- Keep the diff to one concern. A refactor and a fix in the same PR is two PRs.

## Setting up

You need a working Omarchy Quattro install, because the tests run against the
real shell, the real marketplace feed and your actually-installed plugins rather
than fixtures.

```bash
git clone https://github.com/OmarCodeHub/omarchy-marketplace.git
cd omarchy-marketplace
```

To run your working copy, install it:

```bash
omarchy plugin add https://github.com/OmarCodeHub/omarchy-marketplace.git --enable
```

Then edit in `~/.config/omarchy/plugins/io.github.omarcodehub.plugin-manager/`
directly, and push from there.

## Checks

All three must pass:

```bash
node test-model.js                          # 113 assertions against live data
qmllint -I /usr/share/omarchy/shell *.qml   # must be silent
omarchy plugin validate .                   # manifest + entry points
bash -n bin/*                               # shell syntax
```

`test-model.js` deliberately runs against this machine's real catalog and real
installed plugins. It fails when the upstream feed changes shape, which is the
point. A fixture would keep passing while the app broke.

If you add a field, a sort, or a helper in `bin/`, add assertions for it. The
existing tests check that every offered sort actually orders by the field it
names, and that the four count-based sorts produce different results. That
class of test catches the bugs that matter here.

## Things that will bite you

These are all load-bearing. Each one cost a debugging session to find.

**After editing any `.qml`, run `omarchy restart shell`.** Saving reloads the
plugin and closes the panel, but the shell can go on serving the previously
compiled component. You will otherwise chase a bug you have already fixed.

**The panel is destroyed by its own actions.** Every `omarchy plugin` command
ends in `omarchy-shell shell rescanPlugins`, which sets `panelEntries = []` in
the shell and destroys every panel. `keepLoaded` does not save you. Enabling a
panel-kind plugin destroys it a second time by growing that array. So no QML
property may be treated as durable across an action. Anything that must survive
goes to `$XDG_RUNTIME_DIR` via `bin/pm-job`, which runs detached and re-summons
the panel afterwards. A Quickshell `Process` owned by the panel dies with it and
has no detach option.

**The list delegate is anchor-based on purpose.** `PluginRow.qml` uses anchors,
not `RowLayout`/`ColumnLayout`. It is recycled (`reuseItems`) in a list whose
model is reassigned several times per open. With nested layouts a record swap
changes children's implicit sizes mid-rearrange and Qt floods the shell log with
"Detected recursive rearrange". Do not "tidy" it into layouts.

**Thumbnails need `asynchronous: true` and must not set `cache: false`.** The
default is synchronous, which blocks the shell's UI thread on every network
fetch. With delegate recycling, `cache: false` re-downloads the same image every
time it scrolls back into view.

**Read theme values declaratively.** `Color.*` and `Style.*` are singletons a
theme switch reassigns, and every binding re-evaluates on its own. A value
copied into a variable inside a function freezes at the old theme.

**A key must mean the same thing in every view.** `Panel.qml` states the model
above its key handling: arrows move the cursor inside a view, `Tab` steps
between views, the `Ctrl` chords are destinations rather than toggles, and `Esc`
leaves whatever is covering the list before it closes the window. A binding that
does one thing in the list and another in the bar editor forces the hint footer
to label the same key two ways, which is how it drifted the first time.

## Security non-negotiables

A plugin is arbitrary QML running unsandboxed inside a long-lived shell process,
and this one installs other plugins. Two rules hold without exception:

1. **`bin/pm-act` is the only thing that may change the system**, and it takes a
   verb plus validated arguments, never a command string. The marketplace feed
   ships an `installCommand` and it is deliberately ignored. Only the repository
   URL crosses the boundary, and the argv is rebuilt locally.
2. **Validate before you act.** URLs: `https://` only, no git options, no
   `ext::` or other transport helpers, no scp-form, no local paths, and then
   `omarchy-git-url-check`. Plugin ids must match the id pattern and already
   exist on disk. Setting keys are an allowlist, not a passthrough.

A PR that widens either of these needs a very good reason in its description.

## Versioning

The version in `manifest.json` is what the marketplace listing shows, and it
follows [semantic versioning](https://semver.org):

| | when it goes up |
|---|---|
| **major** | something that was working stops working: a setting is removed, the plugin id changes, a documented entry point or command disappears |
| **minor** | a new user-visible capability |
| **patch** | fixes, performance and internals, with no new capability |

A pull request that adds a capability or changes behaviour bumps the version in
`manifest.json` and adds its entry to `CHANGELOG.md` in the same commit, so the
listing and the changelog never disagree with what is on `main`. A release is
tagged `v<version>` on the merge commit. The marketplace revalidates `main` on
its own and picks the new version up from the manifest, so there is nothing to
resubmit.

## Commits and pull requests

- Present tense, imperative subject: "Add X", not "Added X" or "Adds X".
- Explain **why** in the body, not what the diff already shows.
- No em dashes or semicolons in commit messages, PR text or documentation.
- No AI or assistant attribution trailers.
- Reference the issue if there is one.

Open the PR against `main`, describe what you changed and how you verified it,
and note anything you could not test.

## Reporting bugs

Use the issue templates. They ask for `omarchy version`, the plugin version and
the relevant lines from `qs log`, which are the three things needed to reproduce
almost anything here.

For a security issue, do not open a public issue. See the note in the bug
template.
