import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons

// Arranging the bar, by keyboard or by dragging.
//
// Omarchy can move and place bar widgets from the command line but shows the
// arrangement nowhere, so this is the view of it. The three columns are drawn
// the way the bar is laid out, left to right, because that is the thing being
// edited.
//
// The selection is tracked by widget id, never by position. Every edit reloads
// the layout from the shell, and after a move the indexes have all shifted, so
// a positional cursor would silently end up on a different widget than the one
// the user was looking at.
Item {
  id: barView

  // Not `data`: that is Item's default property, the list holding a component's
  // own children. Declaring it shadows the children and the view renders
  // nothing, with no error from qmllint or the runtime.
  property var barData: null
  property bool busy: false

  // The widget under the cursor, by id.
  property string selectedId: ""

  signal moveWidget(string id, string section, int index)
  signal putWidget(string id, string section, int index)
  signal removeWidget(string id)
  signal revertLayout()

  readonly property var sections: barData && barData.sections ? barData.sections : []
  readonly property var available: barData && barData.available ? barData.available : []
  readonly property var order: ["left", "center", "right"]

  function widgetsIn(name) {
    for (var i = 0; i < sections.length; i++)
      if (sections[i].section === name)
        return sections[i].widgets
    return []
  }

  // Everything selectable, in reading order: the three columns top to bottom,
  // then the unplaced row. One flat list keeps cursor movement simple and
  // keeps "where am I" answerable by a single lookup.
  readonly property var flat: {
    var out = []
    for (var s = 0; s < order.length; s++) {
      var list = widgetsIn(order[s])
      for (var i = 0; i < list.length; i++)
        out.push({ id: list[i].id, section: order[s], index: i, placed: true, widget: list[i] })
    }
    for (var a = 0; a < available.length; a++)
      out.push({ id: available[a].id, section: "", index: a, placed: false, widget: available[a] })
    return out
  }

  function entryFor(id) {
    for (var i = 0; i < flat.length; i++)
      if (flat[i].id === id)
        return flat[i]
    return null
  }

  readonly property var current: selectedId === "" ? null : entryFor(selectedId)

  // Keep a selection alive across reloads. If the selected widget is gone,
  // fall back to the first thing there is rather than to nothing.
  onFlatChanged: {
    if (flat.length === 0) {
      selectedId = ""
      return
    }
    if (selectedId === "" || entryFor(selectedId) === null)
      selectedId = flat[0].id
  }

  // ── cursor ──────────────────────────────────────────────────────────────
  // Moves the highlight only. Never changes the bar.
  function moveCursor(dx, dy) {
    if (flat.length === 0)
      return
    var cur = current
    if (!cur) {
      selectedId = flat[0].id
      return
    }

    if (dy !== 0) {
      if (cur.placed) {
        var col = widgetsIn(cur.section)
        var t = cur.index + dy
        if (t >= 0 && t < col.length) {
          selectedId = col[t].id
          return
        }
        // Falling off the bottom of a column steps into the unplaced row.
        if (t >= col.length && available.length > 0) {
          selectedId = available[0].id
          return
        }
        return
      }
      if (dy < 0) {
        var back = widgetsIn("left")
        selectedId = back.length ? back[back.length - 1].id : flat[0].id
        return
      }
      var ni = Math.min(available.length - 1, cur.index + dy)
      selectedId = available[ni].id
      return
    }

    if (dx !== 0) {
      if (!cur.placed) {
        var na = Math.max(0, Math.min(available.length - 1, cur.index + dx))
        selectedId = available[na].id
        return
      }
      var si = order.indexOf(cur.section)
      var ns = Math.max(0, Math.min(order.length - 1, si + dx))
      if (ns === si)
        return
      var dest = widgetsIn(order[ns])
      if (dest.length === 0)
        return
      selectedId = dest[Math.min(cur.index, dest.length - 1)].id
    }
  }

  // ── moving the widget ───────────────────────────────────────────────────
  // Uppercase HJKL. The selection is by id, so it stays on the same widget
  // after the layout reloads and a run of presses keeps acting on it.
  function shiftSelected(dx, dy) {
    var cur = current
    if (!cur || barView.busy)
      return

    if (!cur.placed) {
      // Unplaced: any horizontal press drops it into that end of the bar.
      var target = dx < 0 ? "left" : dx > 0 ? "right" : "center"
      barView.putWidget(cur.id, target, widgetsIn(target).length)
      return
    }

    if (dx !== 0) {
      var si = order.indexOf(cur.section)
      var ns = Math.max(0, Math.min(order.length - 1, si + dx))
      if (ns === si)
        return
      barView.moveWidget(cur.id, order[ns], widgetsIn(order[ns]).length)
      return
    }

    if (dy !== 0) {
      var col = widgetsIn(cur.section)
      var to = cur.index + dy
      if (to < 0 || to >= col.length)
        return
      barView.moveWidget(cur.id, cur.section, to)
    }
  }

  function removeCursorWidget() {
    var cur = current
    if (!cur || !cur.placed || barView.busy)
      return
    barView.removeWidget(cur.id)
  }

  function activateCursor() {
    var cur = current
    if (!cur || barView.busy)
      return
    if (!cur.placed)
      barView.putWidget(cur.id, "right", widgetsIn("right").length)
  }

  // What is being dragged, so every drop area can ask about it.
  property string dragId: ""
  property bool dragPlaced: false

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

      Button {
        text: "Undo my changes"
        tooltipText: "Put the bar back the way it was when this view opened"
        fontSize: Style.font.caption
        enabled: !barView.busy
        onClicked: barView.revertLayout()
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
      text: "Drag a widget where you want it, or move the cursor with the arrows "
        + "and press uppercase H, J, K or L to move the widget itself. x takes "
        + "one off the bar."
    }

    // ── the three sections, drawn as the bar is ──────────────────────────
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Style.spacing.controlGap

      Repeater {
        model: barView.sections
        delegate: SectionColumn {
          required property var modelData
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          section: modelData.section
          widgets: modelData.widgets
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
            width: Math.min(Style.space(170), barView.width / 3)
            widget: modelData
            placed: false
          }
        }
      }
    }
  }

  // One bar section: a labelled column that accepts drops.
  component SectionColumn: ColumnLayout {
    id: col
    property string section: ""
    property var widgets: []

    spacing: Style.spacing.xxs

    Text {
      text: col.section.toUpperCase()
      color: dropArea.containsDrag ? Color.accent : Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      Layout.bottomMargin: Style.spacing.xxs
    }

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: dropArea.containsDrag ? Util.alpha(Color.accent, 0.10) : "transparent"
        border.width: dropArea.containsDrag ? Style.normalBorderWidth : 0
        border.color: Color.accent
      }

      ColumnLayout {
        id: stack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.xxs

        Repeater {
          model: col.widgets
          delegate: WidgetRow {
            required property var modelData
            Layout.fillWidth: true
            widget: modelData
            placed: true
          }
        }

        Text {
          visible: col.widgets.length === 0
          text: "empty"
          color: Util.alpha(Color.popups.text, 0.35)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          Layout.topMargin: Style.spacing.xs
        }
      }

      // The whole column is the target. The insertion point comes from where
      // in the column the pointer is, so a drop lands where it looks like it
      // will rather than always at the end.
      DropArea {
        id: dropArea
        anchors.fill: parent

        onDropped: function (drop) {
          var id = barView.dragId
          if (id === "")
            return
          var rowH = Style.spacing.popupRowHeight + Style.spacing.xxs
          var idx = Math.max(0, Math.min(col.widgets.length, Math.round(drop.y / rowH)))
          if (barView.entryFor(id) && barView.entryFor(id).placed)
            barView.moveWidget(id, col.section, idx)
          else
            barView.putWidget(id, col.section, idx)
          barView.dragId = ""
        }
      }
    }
  }

  // One widget. Draggable, clickable, and the keyboard cursor lands on it.
  component WidgetRow: Rectangle {
    id: row
    property var widget: null
    property bool placed: true
    readonly property bool hasCursor: row.widget !== null && barView.selectedId === row.widget.id

    implicitHeight: Style.spacing.popupRowHeight
    radius: Style.cornerRadius
    color: row.hasCursor ? Color.menu.selectedBackground
      : rowMouse.containsMouse ? Style.hoverFill : Util.alpha(Color.foreground, 0.04)
    border.width: row.hasCursor ? Style.selectedBorderWidth : 0
    border.color: Color.accent
    opacity: Drag.active ? 0.6 : 1

    Drag.active: rowMouse.drag.active
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2

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
      cursorShape: row.placed ? Qt.SizeAllCursor : Qt.PointingHandCursor
      drag.target: barView.busy ? null : row
      drag.threshold: 6

      // Recorded on press rather than when the drag starts: MouseArea has no
      // onDragActiveChanged, drag.active lives in the drag group, and a drop
      // area only reads this at the moment of the drop anyway.
      onPressed: {
        if (!row.widget)
          return
        barView.selectedId = row.widget.id
        barView.dragId = row.widget.id
        barView.dragPlaced = row.placed
      }

      onReleased: {
        if (row.Drag.active)
          row.Drag.drop()
        // The row was dragged out of its layout slot; put it back and let the
        // reloaded data decide where it really belongs.
        row.x = 0
        row.y = 0
        barView.dragId = ""
      }
    }
  }
}
