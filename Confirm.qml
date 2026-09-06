import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Ui
import qs.Commons

// The confirmation step in front of anything that changes the system.
//
// A plugin is arbitrary QML running unsandboxed inside the long-lived
// omarchy-shell process, so this dialog exists to show what is actually about
// to happen -- the exact repository, whether the marketplace has reviewed it,
// and for an update, the real commits and files that are about to land. That
// last part is why bin/pm-act has a read-only `diff` verb: reviewing a change
// should not require applying it first.
Item {
  id: confirm

  // { verb: "install"|"update"|"remove"|"enable"|"disable", record: {...} }
  property var action: null
  property string binDir: ""

  signal confirmed()
  signal cancelled()

  readonly property var record: action ? action.record : null
  readonly property string verb: action ? String(action.verb) : ""
  readonly property bool destructive: verb === "remove"

  // ── the pin ────────────────────────────────────────────────────────────
  // The catalogue says which commit was reviewed; bin/pm-probe observes what
  // the repository points at right now. Two independent sources, so the feed
  // cannot quietly claim a repository has not moved.
  readonly property bool pinning: verb === "install" || verb === "update"
  readonly property string reviewedSha: record && record.reviewedCommit ? String(record.reviewedCommit) : ""
  property var probe: null
  property bool probing: false
  property bool acceptHead: false

  readonly property string headSha: probe && probe.head ? String(probe.head) : ""
  readonly property bool moved: probe !== null && probe.ok === true && probe.moved === true
  readonly property string probeError: probe && probe.ok === false ? String(probe.error || "") : ""

  // What will actually be installed. Defaults to the reviewed commit; only an
  // explicit opt-in switches it to the unreviewed head.
  readonly property string chosenSha: {
    if (!pinning)
      return ""
    if (acceptHead && headSha !== "")
      return headSha
    return reviewedSha
  }

  readonly property bool canProceed: {
    if (!pinning)
      return true
    if (probing)
      return false
    return chosenSha !== ""
  }

  onActionChanged: {
    diffText = ""
    probe = null
    acceptHead = false
    if (!action || binDir === "")
      return
    if (pinning && record && record.repo) {
      probing = true
      probeProc.running = true
    }
    if (verb === "update" && record) {
      diffText = "Fetching the incoming changes..."
      diffProc.running = true
    }
  }

  property string diffText: ""

  // Scrim. Also swallows every click that misses the card, so the dialog is
  // genuinely modal rather than merely on top.
  Rectangle {
    anchors.fill: parent
    color: Color.menu.scrim

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: confirm.cancelled()
    }
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: Math.min(Style.space(560), parent.width - Style.space(48))
    height: Math.min(cardBody.implicitHeight + Style.spacing.huge * 2,
                     parent.height - Style.space(48))
    radius: Style.cornerRadius
    color: Color.menu.background
    border.width: Style.normalBorderWidth
    border.color: Util.alpha(confirm.destructive ? Color.urgent : Color.menu.border,
                             Style.selectedBorderAlpha)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {}
    }

    ColumnLayout {
      id: cardBody
      anchors.fill: parent
      anchors.margins: Style.spacing.huge
      spacing: Style.spacing.md

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: confirm.destructive ? Color.urgent : Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        text: {
          if (!confirm.record)
            return ""
          var name = confirm.record.name
          switch (confirm.verb) {
          case "install": return "Install " + name + "?"
          case "update": return "Update " + name + "?"
          case "remove": return "Remove " + name + "?"
          case "enable": return "Enable " + name + "?"
          case "disable": return "Disable " + name + "?"
          default: return name
          }
        }
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: {
          switch (confirm.verb) {
          case "install":
            return "Omarchy will clone this repository into "
              + "~/.config/omarchy/plugins, validate its manifest, and enable it."
          case "update":
            return "The checkout will be fast-forwarded to its origin and "
              + "re-validated. If validation fails the update is rolled back."
          case "remove":
            return "The plugin's directory is deleted and it is taken out of "
              + "your shell layout. This cannot be undone from here."
          case "enable":
            return "The shell will load this plugin."
          case "disable":
            return "The plugin stays installed but the shell stops loading it."
          default:
            return ""
          }
        }
      }

      // The repository is the thing actually being trusted, so it gets its own
      // line rather than being buried in the prose above.
      Rectangle {
        Layout.fillWidth: true
        visible: confirm.verb === "install" && confirm.record && confirm.record.repo !== ""
        implicitHeight: repoText.implicitHeight + Style.spacing.lg
        radius: Style.cornerRadius
        color: Util.alpha(Color.foreground, 0.06)

        Text {
          id: repoText
          anchors.fill: parent
          anchors.margins: Style.spacing.sm
          text: confirm.record ? confirm.record.repo : ""
          textFormat: Text.PlainText
          wrapMode: Text.WrapAnywhere
          color: Color.menu.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // What commit is about to be installed, and whether it is the one the
      // marketplace actually looked at.
      Rectangle {
        Layout.fillWidth: true
        visible: confirm.pinning
        implicitHeight: pinCol.implicitHeight + Style.spacing.lg
        radius: Style.cornerRadius
        color: Util.alpha(confirm.moved ? Color.urgent : Color.foreground, 0.08)

        ColumnLayout {
          id: pinCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.spacing.sm
          spacing: Style.spacing.xs

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: confirm.moved ? Color.urgent : Color.menu.text
            text: {
              if (confirm.probing)
                return "Checking what the repository points at now..."
              if (confirm.probeError !== "")
                return "Could not reach the repository: " + confirm.probeError
              if (confirm.reviewedSha === "")
                return "The marketplace has no reviewed commit for this listing, so "
                  + "there is nothing to pin to. Installing is not offered."
              if (!confirm.moved)
                return "The repository is still at the commit the marketplace reviewed. "
                  + "Only that commit will be fetched."
              return "This repository has moved since the marketplace reviewed it. "
                + "The newer code has not been reviewed."
            }
          }

          Text {
            Layout.fillWidth: true
            visible: confirm.reviewedSha !== ""
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(Color.menu.text, 0.7)
            text: {
              var out = "reviewed  " + confirm.reviewedSha.substring(0, 12)
              if (confirm.headSha !== "" && confirm.moved)
                out += "\nnow       " + confirm.headSha.substring(0, 12)
              return out
            }
          }

          // Only offered once the repository is known to have moved. The
          // reviewed commit stays the default; taking the head is a deliberate
          // act, not a slip.
          ButtonGroup {
            visible: confirm.moved && confirm.reviewedSha !== ""
            options: [
              { value: "reviewed", label: "Install reviewed" },
              { value: "head", label: "Install newest (unreviewed)" }
            ]
            value: confirm.acceptHead ? "head" : "reviewed"
            fontSize: Style.font.caption
            onChanged: function (v) { confirm.acceptHead = (v === "head") }
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: confirm.verb === "install"
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: confirm.record && confirm.record.verified ? Color.muted : Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: confirm.record && confirm.record.verified
          ? "The marketplace lists this as verified: its source has been reviewed. "
            + "A plugin still runs unsandboxed inside your shell process."
          : "This listing is unverified. A plugin runs as arbitrary, unsandboxed "
            + "code inside your long-lived shell process — read its source before "
            + "you enable it."
      }

      // The incoming diff for an update, straight from git.
      Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: Style.space(90)
        visible: confirm.verb === "update"
        radius: Style.cornerRadius
        color: Util.alpha(Color.foreground, 0.06)

        Flickable {
          anchors.fill: parent
          anchors.margins: Style.spacing.sm
          clip: true
          contentWidth: width
          contentHeight: diffLabel.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Text {
            id: diffLabel
            width: parent.width
            text: confirm.diffText
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            color: Util.alpha(Color.menu.text, 0.85)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.spacing.xs
        spacing: Style.spacing.md

        Item { Layout.fillWidth: true }

        Button {
          text: "Cancel"
          onClicked: confirm.cancelled()
        }

        Button {
          bordered: true
          enabled: confirm.canProceed
          foreground: confirm.destructive ? Color.urgent : Color.foreground
          text: {
            switch (confirm.verb) {
            case "install": return "Install"
            case "update": return "Update"
            case "remove": return "Remove"
            case "enable": return "Enable"
            case "disable": return "Disable"
            default: return "Confirm"
            }
          }
          onClicked: confirm.confirmed()
        }
      }
    }
  }

  Process {
    id: probeProc
    command: confirm.binDir === "" || !confirm.record || !confirm.record.repo
      ? [] : [confirm.binDir + "/pm-probe", confirm.record.repo, confirm.reviewedSha]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        confirm.probing = false
        try {
          confirm.probe = JSON.parse(text || "null")
        } catch (e) {
          confirm.probe = null
        }
      }
    }
    onExited: confirm.probing = false
  }

  Process {
    id: diffProc
    command: confirm.binDir === "" || !confirm.record
      ? [] : [confirm.binDir + "/pm-act", "diff", confirm.record.id, confirm.reviewedSha]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").replace(/__PM_DONE__ \d+\s*$/, "").trim()
        confirm.diffText = out === "" ? "No changes reported." : out
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg !== "")
          confirm.diffText = msg
      }
    }
  }
}
