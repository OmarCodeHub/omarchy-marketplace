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

  onActionChanged: {
    diffText = ""
    if (action && verb === "update" && record && binDir !== "") {
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
    id: diffProc
    command: confirm.binDir === "" || !confirm.record
      ? [] : [confirm.binDir + "/pm-act", "diff", confirm.record.id]
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
