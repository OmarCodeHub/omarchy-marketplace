import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons

// Arranging the bar.
//
// Omarchy can move and place bar widgets from the command line but shows the
// arrangement nowhere, so this is the view of it. The three columns are laid
// out the way the bar is, left to right, because that is the thing being
// edited and a vertical list would hide it.
//
// Everything here is keyboard-driven first. Arrows move the cursor between
// widgets, the same arrows with Shift move the widget itself, and the mouse is
// a second way in rather than the only one.
Item {
  id: barView

  // Not `data`: that is Item's default property, the list holding a component's
  // own children. Declaring it shadows the children and the view renders
  // nothing, with no error from qmllint or the runtime.
  property var barData: null
  property string selectedId: ""
  property bool busy: false

  // section + index for the widget the cursor is on, or the availability row.
  property string cursorSection: "left"
  property int cursorIndex: 0
  property bool cursorInAvailable: false

  signal moveWidget(string id, string section, int index)
  signal putWidget(string id, string section, int index)
  signal removeWidget(string id)

  readonly property var sections: barData && barData.sections ? barData.sections : []
  readonly property var available: barData && barData.available ? barData.available : []

  function sectionAt(name) {
    for (var i = 0; i < sections.length; i++)
      if (sections[i].section === name)
        return sections[i]
    return null
  }

  function widgetsIn(name) {
    var s = sectionAt(name)
    return s ? s.widgets : []
  }

  readonly property var cursorWidget: {
    if (cursorInAvailable)
      return cursorIndex >= 0 && cursorIndex < available.length ? available[cursorIndex] : null
    var list = widgetsIn(cursorSection)
    return cursorIndex >= 0 && cursorIndex < list.length ? list[cursorIndex] : null
  }

  readonly property var order: ["left", "center", "right"]

  // ── cursor ──────────────────────────────────────────────────────────────
  // Moves the highlight. Never changes the bar.
  function moveCursor(dx, dy) {
    if (cursorInAvailable) {
      if (dy < 0 && cursorIndex === 0) {
        // Step back up into whichever column the cursor came from.
        cursorInAvailable = false
        cursorIndex = Math.max(0, widgetsIn(cursorSection).length - 1)
        return
      }
      if (dx !== 0 || dy !== 0)
        cursorIndex = Math.max(0, Math.min(available.length - 1, cursorIndex + dy + dx))
      return
    }

    if (dx !== 0) {
      var i = order.indexOf(cursorSection)
      var next = Math.max(0, Math.min(order.length - 1, i + dx))
      cursorSection = order[next]
      cursorIndex = Math.max(0, Math.min(widgetsIn(cursorSection).length - 1, cursorIndex))
      return
    }

    if (dy !== 0) {
      var list = widgetsIn(cursorSection)
      var target = cursorIndex + dy
      if (target >= list.length && available.length > 0) {
        cursorInAvailable = true
        cursorIndex = 0
        return
      }
      cursorIndex = Math.max(0, Math.min(list.length - 1, target))
    }
  }

  // ── moving the widget itself ────────────────────────────────────────────
  // Shift plus an arrow. Left and right change section, up and down reorder
  // within one. The cursor follows the widget so a run of presses keeps
  // acting on the same thing.
  function shiftSelected(dx, dy) {
    var w = cursorWidget
    if (!w || barView.busy)
      return

    if (cursorInAvailable) {
      // An available widget has no place yet; any arrow drops it into a column.
      var target = dx < 0 ? "left" : dx > 0 ? "right" : "center"
      barView.putWidget(w.id, target, 0)
      return
    }

    if (dx !== 0) {
      var i = order.indexOf(w.section)
      var ni = Math.max(0, Math.min(order.length - 1, i + dx))
      if (ni === i)
        return
      var dest = order[ni]
      cursorSection = dest
      cursorIndex = widgetsIn(dest).length
      barView.moveWidget(w.id, dest, widgetsIn(dest).length)
      return
    }

    if (dy !== 0) {
      var list = widgetsIn(w.section)
      var to = w.index + dy
      if (to < 0 || to >= list.length)
        return
      cursorIndex = to
      barView.moveWidget(w.id, w.section, to)
    }
  }

  function removeCursorWidget() {
    var w = cursorWidget
    if (!w || cursorInAvailable || barView.busy)
      return
    barView.removeWidget(w.id)
  }

  function activateCursor() {
    var w = cursorWidget
    if (!w || barView.busy)
      return
    if (cursorInAvailable)
      barView.putWidget(w.id, "right", widgetsIn("right").length)
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: Style.normalBorderWidth
    border.color: Util.alpha(Color.popups.border, Style.normalBorderAlpha)
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.spacing.panelPadding
    spacing: Style.spacing.md

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.controlGap

      Text {
        text: "Bar layout"
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        textFormat: Text.PlainText
      }

      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: barView.barData
          ? "bar at the " + barView.barData.barPosition + "  ·  "
            + barView.barData.counts.placed + " placed  ·  "
            + barView.barData.counts.available + " available"
          : ""
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      text: "Arrows move the cursor. Shift with left or right moves a widget "
        + "between sections, Shift with up or down reorders it. Delete takes "
        + "one off the bar."
    }

    // ── the three sections, laid out as the bar is ───────────────────────
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Style.spacing.controlGap

      Repeater {
        model: barView.sections
        delegate: ColumnLayout {
          required property var modelData
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          spacing: Style.spacing.xxs

          Text {
            text: modelData.section.toUpperCase()
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            Layout.bottomMargin: Style.spacing.xxs
          }

          Repeater {
            model: modelData.widgets
            delegate: WidgetRow {
              required property var modelData
              Layout.fillWidth: true
              widget: modelData
              hasCursor: !barView.cursorInAvailable
                && barView.cursorSection === modelData.section
                && barView.cursorIndex === modelData.index
              onClicked: {
                barView.cursorInAvailable = false
                barView.cursorSection = modelData.section
                barView.cursorIndex = modelData.index
              }
            }
          }

          Text {
            visible: modelData.widgets.length === 0
            text: "empty"
            color: Util.alpha(Color.popups.text, 0.35)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            Layout.topMargin: Style.spacing.xs
          }

          Item { Layout.fillHeight: true }
        }
      }
    }

    PanelSeparator {
      Layout.fillWidth: true
      visible: barView.available.length > 0
    }

    // ── installed but not placed ─────────────────────────────────────────
    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xxs
      visible: barView.available.length > 0

      Text {
        text: "NOT ON THE BAR"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }

      Flow {
        Layout.fillWidth: true
        spacing: Style.spacing.sm

        Repeater {
          model: barView.available
          delegate: WidgetRow {
            required property var modelData
            required property int index
            width: Math.min(Style.space(170), barView.width / 3)
            widget: modelData
            hasCursor: barView.cursorInAvailable && barView.cursorIndex === index
            onClicked: {
              barView.cursorInAvailable = true
              barView.cursorIndex = index
            }
          }
        }
      }
    }
  }

  // One widget, in a section or in the availability row.
  component WidgetRow: Rectangle {
    id: row
    property var widget: null
    property bool hasCursor: false

    signal clicked()

    implicitHeight: Style.spacing.popupRowHeight
    radius: Style.cornerRadius
    color: row.hasCursor ? Color.menu.selectedBackground
      : rowMouse.containsMouse ? Style.hoverFill : Util.alpha(Color.foreground, 0.04)
    border.width: row.hasCursor ? Style.selectedBorderWidth : 0
    border.color: Color.accent

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.spacing.sm
      anchors.rightMargin: Style.spacing.sm
      spacing: Style.spacing.xs

      Text {
        Layout.fillWidth: true
        text: row.widget ? row.widget.name : ""
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: row.widget && row.widget.missing ? Color.urgent
          : row.hasCursor ? Color.menu.selectedText : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // A widget whose plugin is gone still occupies a slot; say so rather
      // than drawing a blank row.
      Text {
        visible: row.widget !== null && row.widget.missing === true
        text: "missing"
        textFormat: Text.PlainText
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: row.clicked()
    }
  }
}
