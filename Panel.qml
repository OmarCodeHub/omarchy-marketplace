import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Plugin manager: browse the Omarchy marketplace, install, update, enable,
// disable and remove shell plugins.
//
// Summon it with:
//   omarchy-shell shell toggle io.github.omarcodehub.plugin-manager
//
// Notes for anyone editing this:
//
// 1. THIS PANEL IS DESTROYED BY ITS OWN ACTIONS. Every omarchy plugin command
//    ends in `omarchy-shell shell rescanPlugins`, and that reload sets
//    `panelEntries = []` in shell.qml, destroying every panel delegate --
//    `keepLoaded` does not help, because an empty model has no delegate left to
//    evaluate it. Enabling a panel-kind plugin destroys it a second time, by
//    growing the array. So no QML property here may be treated as durable
//    across an action: nothing survives but the window.
//
//    Everything that must outlive a mutation is written to $XDG_RUNTIME_DIR by
//    bin/pm-job, which runs detached (a Quickshell Process would be killed with
//    its parent, and Process has no detach property). When the job finishes it
//    re-summons this panel with {"resume": "<jobId>"}, and open() rehydrates
//    from disk. saveUi()/restoreUi() carry the scroll position and selection
//    across that gap so the round-trip is invisible.
//
// 2. All parsing and filtering lives in Model.js and is tested under node
//    (`node test-model.js`, run against this machine's real catalog and real
//    installed plugins). This file is wiring and layout only.
//
// 3. Theme values are read declaratively (Color.*, Style.*). A theme switch
//    reassigns those singleton properties and every binding re-evaluates; a
//    value copied into a var in a function would freeze at the old theme.
//
// 4. The window is tiled by Hyprland at an arbitrary size unless the user adds
//    the window rule from the README, so the layout reflows: the sidebar and
//    the detail pane drop out as it narrows.
Item {
  id: root

  // ─────────────────────────────────────────────── plugin lifecycle
  // Injected by the host after construction (shell.qml:629-637), so these are
  // still null in Component.onCompleted. First use happens in open().
  property var shell: null
  property var manifest: null
  property bool closingFromHost: false

  // shell.qml reads `loader.item.opened` to decide what toggle does.
  readonly property bool opened: window.visible

  readonly property string pluginId: "io.github.omarcodehub.plugin-manager"
  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string binDir: sourceDir === "" ? "" : sourceDir + "/bin"
  readonly property string jobDir: Quickshell.env("XDG_RUNTIME_DIR") + "/io.github.omarcodehub.plugin-manager"

  function setting(name, fallback) {
    var d = manifest && manifest.panel && manifest.panel.defaults ? manifest.panel.defaults : null
    var v = d ? d[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  function open(payloadJson) {
    closingFromHost = false

    var payload = {}
    try {
      payload = JSON.parse(payloadJson || "{}") || {}
    } catch (e) {
      payload = {}
    }

    // A resume means a job we started finished while we were dead. Adopt it so
    // the result is shown instead of silently vanishing.
    var resume = String(payload.resume || "")
    if (resume !== "") {
      root.jobId = resume
      root.restoreOnLoad = true
    }

    // Deep link: `omarchy-shell shell summon io.github.omarcodehub.plugin-manager '{"select":"<id>"}'`
    // opens straight to one plugin, so other tooling can hand the user off to
    // the thing they were reading about.
    var select = String(payload.select || "")
    if (select !== "") {
      root.selectedId = select
      root.scope = "all"
      root.restoreOnLoad = false
      root.scrollToSelected = true
    }

    // `{"view":"settings"}` opens straight into Settings, so the Omarchy menu
    // or a keybinding can go there directly.
    var view = String(payload.view || "")
    if (view !== "")
      root.showSettings = (view === "settings")

    window.visible = true
    root.reload(false)
    Qt.callLater(function () {
      if (!root.restoreOnLoad)
        searchField.forceActiveFocus()
    })
  }

  // Host-initiated close: flip visibility without telling the host, which
  // already knows.
  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  // User-initiated close: tell the shell so its open-panel map stays
  // consistent and the next toggle behaves.
  function requestClose() {
    saveUi()
    if (shell && typeof shell.hide === "function")
      shell.hide(root.pluginId)
    else
      window.visible = false
  }

  // Probed by bin/pm-job over `omarchy-shell shell call` to find out whether
  // its re-summon actually landed. While this panel is unloaded the shell
  // answers the literal string "unknown" on our behalf.
  function resumeStatus(wantJobId) {
    if (String(wantJobId || "") !== root.jobId)
      return "miss"
    return window.visible ? "shown" : "hidden"
  }

  // ─────────────────────────────────────────────── data
  property var catalog: null
  property var localState: null
  property var updateState: null
  property var statsState: null
  property var records: []
  property var rows: []

  property bool loadingCatalog: false
  property bool loadingLocal: false
  property bool checkingUpdates: false
  property bool loadingStats: false
  readonly property bool busy: loadingCatalog || loadingLocal || checkingUpdates
  property string loadError: ""

  // ─────────────────────────────────────────────── view state
  property string scope: "browse"
  property string query: ""
  property string category: ""
  property string sortBy: "stars"
  property bool verifiedOnly: false
  property string selectedId: ""
  property bool restoreOnLoad: false
  property bool scrollToSelected: false
  property bool showSettings: false
  // Only meaningful while the window is too narrow for the inline column.
  property bool sidebarOpen: false

  readonly property var selected: {
    if (root.selectedId === "")
      return null
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].id === root.selectedId)
        return root.rows[i]
    // Still show a selection that the current filter excludes -- e.g. after
    // installing something while the Browse filter is on Updates.
    for (var j = 0; j < root.records.length; j++)
      if (root.records[j].id === root.selectedId)
        return root.records[j]
    return null
  }

  readonly property var counts: root.records.length ? Model.countsOf(root.records) : ({
    installed: 0, updates: 0, enabled: 0, builtin: 0, browse: 0
  })

  readonly property var scopes: [
    { key: "browse", label: "Browse", count: root.counts.browse },
    { key: "installed", label: "Installed", count: root.counts.installed },
    { key: "updates", label: "Updates", count: root.counts.updates },
    { key: "enabled", label: "Enabled", count: root.counts.enabled },
    { key: "builtin", label: "Built-in", count: root.counts.builtin },
    { key: "all", label: "Everything", count: root.records.length }
  ]

  readonly property var categories: root.records.length
    ? Model.categoriesOf(root.records, root.scope) : []

  // ─────────────────────────────────────────────── previews
  // No Image in this plugin ever points at a remote URL. Rows ask for a
  // catalogue-relative path, bin/pm-preview fetches it from the fixed origin
  // under byte, time, dimension and concurrency limits, and only the validated
  // local file is displayed. Requests are batched on a short timer so scrolling
  // does not spawn a process per row.
  property var previewCache: ({})
  property var previewPending: ({})
  property var previewQueue: []
  property int previewRevision: 0

  function requestPreview(rel) {
    if (!rel || root.binDir === "")
      return
    if (root.previewCache[rel] !== undefined || root.previewPending[rel] === true)
      return
    root.previewPending[rel] = true
    root.previewQueue.push(rel)
    previewTimer.restart()
  }

  // previewRevision is passed in by callers purely so the binding re-evaluates
  // when a batch lands; the value itself is unused.
  function previewSource(rel, revision) {
    if (!rel)
      return ""
    var local = root.previewCache[rel]
    return local ? "file://" + local : ""
  }

  Timer {
    id: previewTimer
    interval: 200
    onTriggered: root.flushPreviews()
  }

  Process {
    id: previewProc
    property var batch: []
    command: root.binDir === "" || batch.length === 0
      ? [] : [root.binDir + "/pm-preview"].concat(batch)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = ({})
        for (var k in root.previewCache)
          next[k] = root.previewCache[k]
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i])
            continue
          var parts = lines[i].split("\t")
          if (parts.length === 2 && parts[1])
            next[parts[0]] = parts[1]
        }
        root.previewCache = next
        root.previewRevision++
      }
    }
    onExited: {
      // Anything the helper declined stays out of the cache; clearing it from
      // pending would only make the row ask again on every scroll.
      previewProc.batch = []
      if (root.previewQueue.length > 0)
        previewTimer.restart()
    }
  }

  function flushPreviews() {
    if (previewProc.running || root.previewQueue.length === 0 || root.binDir === "")
      return
    previewProc.batch = root.previewQueue.splice(0, 40)
    previewProc.running = true
  }

  // ─────────────────────────────────────────────── job state
  property string jobId: ""
  property var job: null
  property string jobLog: ""
  property var pendingAction: null

  readonly property bool jobRunning: root.job !== null && root.job.state === "running"

  function reload(force) {
    if (root.binDir === "")
      return
    root.loadError = ""
    root.loadingCatalog = true
    catalogProc.forceRefresh = force === true
    catalogProc.running = true
    root.loadingStats = true
    statsProc.forceRefresh = force === true
    statsProc.running = true
    root.refreshLocal()
  }

  // Local inventory and the update check are cheap and independent of the
  // catalog, so they are not sequenced behind it.
  function refreshLocal() {
    if (root.binDir === "")
      return
    root.loadingLocal = true
    localProc.running = true
    root.checkingUpdates = true
    updatesProc.running = true
  }

  function rebuild() {
    root.records = Model.mergeState(root.catalog, root.localState, root.updateState, root.statsState)
    root.applyFilter()
    if (root.restoreOnLoad) {
      root.restoreOnLoad = false
      root.restoreUi()
    }
  }

  function applyFilter() {
    root.rows = Model.filterAndSort(root.records, {
      query: root.query,
      scope: root.scope,
      category: root.category,
      // Always the chosen sort: Model.filterAndSort puts relevance ahead of it
      // on its own while a query is present, so the control keeps working
      // during a search rather than being quietly ignored.
      sort: root.sortBy,
      verifiedOnly: root.verifiedOnly
    })
    // Clamp rather than reset: a filter change that keeps the selection
    // visible should not throw the user back to the top.
    if (list.contentY > list.contentHeight)
      list.contentY = 0

    if (root.scrollToSelected && root.selectedId !== "") {
      for (var i = 0; i < root.rows.length; i++) {
        if (root.rows[i].id === root.selectedId) {
          root.scrollToSelected = false
          list.currentIndex = i
          // Deferred: positioning straight out of a model swap runs against
          // the view's old geometry.
          Qt.callLater(function () { list.positionViewAtIndex(i, ListView.Center) })
          break
        }
      }
    }
  }

  function chooseCategory(name) {
    root.category = root.category === name ? "" : name
    root.applyFilter()
    list.contentY = 0
    root.sidebarOpen = false
  }

  function setScope(next) {
    if (root.scope === next)
      return
    root.scope = next
    root.category = ""
    root.applyFilter()
    list.contentY = 0
    root.sidebarOpen = false
  }

  function selectIndex(i) {
    if (i < 0 || i >= root.rows.length)
      return
    root.selectedId = root.rows[i].id
    list.currentIndex = i
    list.positionViewAtIndex(i, ListView.Contain)
  }

  function moveSelection(delta) {
    if (root.rows.length === 0)
      return
    var i = list.currentIndex + delta
    if (i < 0)
      i = 0
    if (i >= root.rows.length)
      i = root.rows.length - 1
    root.selectIndex(i)
  }

  // ─────────────────────────────────────────────── actions

  // Nothing from the marketplace feed is ever executed. The catalog ships an
  // `installCommand` string and it is deliberately ignored: only the verb and
  // the repository URL cross into bin/pm-act, which rebuilds the argv itself.
  function requestAction(verb, record) {
    if (root.jobRunning)
      return
    root.pendingAction = { verb: verb, record: record }
  }

  function confirmAction() {
    var pending = root.pendingAction
    if (!pending)
      return

    // Read the dialog's choice BEFORE dismissing it. `Confirm.action` is bound
    // to pendingAction, so clearing it first collapses chosenSha to "" and the
    // install is dropped on the floor with no error anywhere -- which is
    // exactly the silent no-op this used to produce.
    var chosen = confirmSheet.chosenSha
    root.pendingAction = null

    var record = pending.record
    var args = []
    if (pending.verb === "install") {
      // The sha the dialog settled on: the reviewed commit, or the current head
      // if the user explicitly chose it after being told it is unreviewed.
      var sha = chosen || record.reviewedCommit
      if (!sha) {
        root.loadError = "No reviewed commit is published for " + record.name
          + ", so it cannot be installed safely."
        return
      }
      args = ["install", record.repo, record.id, sha]
    } else if (pending.verb === "update") {
      var target = chosen || record.reviewedCommit
      if (!target) {
        root.loadError = "No reviewed commit is published for " + record.name + "."
        return
      }
      args = ["update", record.id, target]
    } else {
      args = [pending.verb, record.id]
    }

    root.startJob(pending.verb, record.id, args)
  }

  function startJob(verb, subjectId, args) {
    if (root.binDir === "" || root.jobRunning)
      return

    // No Date.now(): a monotonic counter persisted in the job dir would be
    // nicer, but the id only has to be unique among live jobs, and the panel's
    // own object address is not stable across the destruction this job causes.
    root.jobSeq = root.jobSeq + 1
    var id = "job-" + root.jobSeq + "-" + verb + "-" + subjectId.replace(/[^A-Za-z0-9_-]/g, "")

    root.selectedId = subjectId
    root.saveUi()
    root.jobId = id
    root.job = { id: id, verb: verb, state: "running", exit: null }
    root.jobLog = ""

    // Detached on purpose: this panel is about to be destroyed by the very
    // command it is starting.
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash",
      root.binDir + "/pm-job", root.pluginId, root.jobDir, id].concat(args))
  }

  property int jobSeq: 0

  function dismissJob() {
    root.jobId = ""
    root.job = null
    root.jobLog = ""
    root.refreshLocal()
  }

  // ─────────────────────────────────────────────── ui state across a restart

  function saveUi() {
    if (root.jobDir === "")
      return
    uiFile.setText(JSON.stringify({
      scope: root.scope,
      query: root.query,
      category: root.category,
      sortBy: root.sortBy,
      verifiedOnly: root.verifiedOnly,
      selectedId: root.selectedId,
      contentY: list.contentY,
      jobSeq: root.jobSeq
    }))
  }

  // Set while restoreUi() is writing state back, so handlers can tell a
  // restored value from something the user just did.
  property bool restoring: false

  function restoreUi() {
    var saved = null
    try {
      saved = JSON.parse(uiFile.text() || "null")
    } catch (e) {
      saved = null
    }
    if (!saved)
      return
    root.restoring = true
    root.scope = String(saved.scope || "browse")
    root.query = String(saved.query || "")
    root.category = String(saved.category || "")
    root.sortBy = String(saved.sortBy || "stars")
    root.verifiedOnly = saved.verifiedOnly === true
    root.selectedId = String(saved.selectedId || "")
    root.jobSeq = Number(saved.jobSeq || 0)
    searchField.text = root.query
    root.applyFilter()
    if (saved.contentY !== undefined)
      Qt.callLater(function () { list.contentY = Number(saved.contentY) || 0 })
    root.restoring = false
  }

  // ─────────────────────────────────────────────── processes (read-only)

  Process {
    id: catalogProc
    property bool forceRefresh: false
    command: root.binDir === "" ? []
      : (forceRefresh ? [root.binDir + "/pm-catalog", "--refresh"] : [root.binDir + "/pm-catalog"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loadingCatalog = false
        try {
          root.catalog = JSON.parse(text || "null")
        } catch (e) {
          root.catalog = null
          root.loadError = "The marketplace catalog could not be parsed."
        }
        if (root.catalog && root.catalog.ok === false)
          root.loadError = String(root.catalog.error || "The marketplace is unreachable.")
        root.rebuild()
      }
    }
    onExited: function (exitCode) {
      root.loadingCatalog = false
      if (exitCode !== 0 && root.loadError === "")
        root.loadError = "Could not read the marketplace catalog (exit " + exitCode + ")."
    }
  }

  Process {
    id: statsProc
    property bool forceRefresh: false
    command: root.binDir === "" ? []
      : (forceRefresh ? [root.binDir + "/pm-stats", "--refresh"] : [root.binDir + "/pm-stats"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loadingStats = false
        try {
          root.statsState = JSON.parse(text || "null")
        } catch (e) {
          root.statsState = null
        }
        root.rebuild()
      }
    }
    // Hearts are decoration. If the engagement API is unreachable the panel
    // must still browse and install, so a failure here is not a load error.
    onExited: root.loadingStats = false
  }

  Process {
    id: localProc
    command: root.binDir === "" ? [] : [root.binDir + "/pm-local"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loadingLocal = false
        try {
          root.localState = JSON.parse(text || "null")
        } catch (e) {
          root.localState = null
        }
        root.rebuild()
      }
    }
    onExited: root.loadingLocal = false
  }

  Process {
    id: updatesProc
    command: root.binDir === "" ? [] : [root.binDir + "/pm-updates"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.checkingUpdates = false
        try {
          root.updateState = JSON.parse(text || "null")
        } catch (e) {
          root.updateState = null
        }
        root.rebuild()
      }
    }
    onExited: root.checkingUpdates = false
  }

  // ─────────────────────────────────────────────── job files

  FileView {
    id: uiFile
    path: root.jobDir === "" ? "" : root.jobDir + "/ui.json"
    printErrors: false
    atomicWrites: false
  }

  FileView {
    id: jobFile
    path: root.jobId === "" ? "" : root.jobDir + "/" + root.jobId + ".json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var next = null
      try {
        next = JSON.parse(text() || "null")
      } catch (e) {
        next = null
      }
      if (next) {
        var wasRunning = root.job && root.job.state === "running"
        root.job = next
        // The plugin list only reflects the change once the job is finished.
        if (wasRunning && next.state !== "running")
          root.refreshLocal()
      }
    }
    onLoadFailed: {
      // Normal at the very start of a job: pm-job has not written the file yet.
    }
  }

  FileView {
    id: logFile
    path: root.jobId === "" ? "" : root.jobDir + "/" + root.jobId + ".log"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.jobLog = text() || ""
    onLoadFailed: root.jobLog = root.jobLog
  }

  // watchChanges is an accelerator, not a guarantee -- the poll is the
  // authority while a job is in flight, which is what omarchy's own CLIs do.
  Timer {
    running: root.jobId !== "" && root.jobRunning
    interval: 250
    repeat: true
    onTriggered: {
      jobFile.reload()
      logFile.reload()
    }
  }

  // ─────────────────────────────────────────────── window

  FloatingWindow {
    id: window

    // Stable and unique: a Quickshell toplevel always reports class
    // org.quickshell, so the title is the only thing a Hyprland window rule can
    // match on. Never put dynamic content here.
    title: "Plugin Depot"
    color: Color.background

    implicitWidth: 1180
    implicitHeight: 820
    // No maximumSize: it makes Hyprland float the window unpredictably
    // depending on the user's current tiling. No maximized: Omarchy suppresses
    // client maximize for every window (default/hypr/windows.lua).
    minimumSize: Qt.size(420, 360)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost)
        root.requestClose()
    }

    // Above `wide` the detail sits beside the list. Below it there is no room
    // for two columns, so selecting a plugin swaps the list out for the detail
    // and the detail grows a Back button -- master-detail, rather than a click
    // that appears to do nothing because the pane it fills is off-layout.
    readonly property bool wide: width >= 900
    readonly property bool showSidebar: width >= 700
    readonly property bool detailTakesOver: !wide && root.selectedId !== ""

    Item {
      id: content
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          // Unwind one layer at a time: dialog, then the detail that replaced
          // the list on a narrow window, then the panel itself.
          if (root.pendingAction) {
            root.pendingAction = null
          } else if (root.sidebarOpen) {
            root.sidebarOpen = false
          } else if (root.showSettings) {
            root.showSettings = false
          } else if (window.detailTakesOver) {
            root.selectedId = ""
          } else {
            root.requestClose()
          }
          event.accepted = true
        } else if (event.key === Qt.Key_F5
                   || (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier))) {
          root.reload(true)
          event.accepted = true
        } else if (event.key === Qt.Key_F11) {
          window.fullscreen = !window.fullscreen
          event.accepted = true
        } else if (event.key === Qt.Key_Slash && !searchField.activeFocus) {
          searchField.forceActiveFocus()
          searchField.selectAll()
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.moveSelection(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.moveSelection(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_PageDown) {
          root.moveSelection(10)
          event.accepted = true
        } else if (event.key === Qt.Key_PageUp) {
          root.moveSelection(-10)
          event.accepted = true
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.lg

        // ───────────────────────────────── header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          Button {
            // Only when the inline column cannot fit. Opens the same switcher
            // as a drawer over the list.
            visible: !window.showSidebar && !root.showSettings
            iconText: "\u2630"
            tooltipText: "Views and categories"
            selected: root.sidebarOpen
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlGap
            onClicked: root.sidebarOpen = !root.sidebarOpen
          }

          Text {
            text: "Plugin Depot"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            textFormat: Text.PlainText
          }

          Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            textFormat: Text.PlainText
            visible: window.width >= 700
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            text: {
              if (root.loadError !== "")
                return root.loadError
              if (root.busy)
                return "Loading..."
              var bits = []
              bits.push(root.counts.browse + " listed")
              bits.push(root.counts.installed + " installed")
              if (root.counts.updates > 0)
                bits.push(root.counts.updates + " update" + (root.counts.updates === 1 ? "" : "s"))
              if (root.catalog && root.catalog.stale)
                bits.push("offline copy")
              return bits.join("  ·  ")
            }
          }

          TextField {
            id: searchField
            Layout.preferredWidth: Math.min(Style.space(320), window.width * 0.4)
            placeholderText: "Search plugins"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: Color.foreground
            onTextChanged: {
              root.query = text
              // On a narrow window the detail has replaced the list, so a
              // search the user cannot see is filtering a hidden view. Drop
              // back to the results. Guarded, because restoreUi() also sets
              // this text and must not throw away the selection it just
              // restored.
              if (!root.restoring && window.detailTakesOver)
                root.selectedId = ""
              root.applyFilter()
            }
            Keys.onDownPressed: {
              content.forceActiveFocus()
              root.moveSelection(1)
            }
            Keys.onEscapePressed: {
              if (text !== "")
                text = ""
              else if (window.detailTakesOver)
                root.selectedId = ""
              else
                root.requestClose()
            }
          }

          Button {
            text: root.busy ? "..." : "Refresh"
            tooltipText: "Re-fetch the marketplace catalog and re-check for updates (F5)"
            fontSize: Style.font.bodySmall
            enabled: !root.busy
            onClicked: root.reload(true)
          }

          Button {
            text: root.showSettings ? "Done" : "Settings"
            tooltipText: root.showSettings
              ? "Back to the plugin list" : "Where this sits in the bar, and how often it checks for updates"
            fontSize: Style.font.bodySmall
            selected: root.showSettings
            onClicked: root.showSettings = !root.showSettings
          }

        }

        // ───────────────────────────────── body
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.lg

          // sidebar, inline when there is room for a column
          Sidebar {
            Layout.preferredWidth: Style.space(180)
            Layout.fillHeight: true
            visible: window.showSidebar && !window.detailTakesOver && !root.showSettings
            scopes: root.scopes
            categories: root.categories
            scope: root.scope
            category: root.category
            onScopeChosen: function (key) { root.setScope(key) }
            onCategoryChosen: function (name) { root.chooseCategory(name) }
          }

          // list
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: Style.space(260)
            spacing: Style.spacing.sm
            visible: !window.detailTakesOver && !root.showSettings

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.controlGap

              // The sidebar carries the scope switcher, but it needs 700px and
              // the window is tiled at whatever Hyprland gives it — commonly
              //621px, where the sidebar is hidden and every scope but Browse
              // became unreachable. This is the same switcher in the space that
              // is always on screen.
              Dropdown {
                Layout.preferredWidth: Math.min(Style.space(190), window.width * 0.32)
                Layout.alignment: Qt.AlignVCenter
                visible: !window.showSidebar
                showLabel: false
                label: "View"
                fontFamily: Style.font.family
                options: root.scopes.map(function (s) {
                  return {
                    value: s.key,
                    label: s.count > 0 ? s.label + "  " + s.count : s.label
                  }
                })
                value: root.scope
                onChanged: function (v) { root.setScope(v) }
              }

              Text {
                // The scope dropdown next to this already shows the view and
                // its count when the sidebar is hidden, so this would only
                // repeat it into a row that has no space to spare.
                visible: window.showSidebar || root.category !== ""
                text: root.rows.length + (root.rows.length === 1 ? " plugin" : " plugins")
                  + (root.category !== "" ? " in " + root.category : "")
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
              }

              Button {
                visible: root.scope === "browse" || root.scope === "all"
                text: root.verifiedOnly ? "Verified only" : "All listings"
                tooltipText: "The marketplace marks a listing verified once its source has been reviewed"
                fontSize: Style.font.caption
                selected: root.verifiedOnly
                onClicked: {
                  root.verifiedOnly = !root.verifiedOnly
                  root.applyFilter()
                }
              }

              Dropdown {
                Layout.preferredWidth: Math.min(Style.space(200), window.width * 0.3)
                Layout.alignment: Qt.AlignVCenter
                showLabel: false
                label: "Sort"
                options: Model.sortOptions()
                value: root.sortBy
                fontFamily: Style.font.family
                onChanged: function (v) {
                  if (!Model.isSort(v))
                    return
                  root.sortBy = v
                  root.applyFilter()
                  list.contentY = 0
                }
              }
            }

            ListView {
              id: list
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              // Mandatory at this row count: without it, scrolling the catalog
              // constructs a delegate per row (measured 2198 vs 9) and restarts
              // a network request for every thumbnail it throws away.
              reuseItems: true
              cacheBuffer: 400
              model: root.rows
              spacing: Style.spacing.xxs
              currentIndex: -1
              boundsBehavior: Flickable.StopAtBounds

              delegate: PluginRow {
                required property var modelData
                required property int index
                width: ListView.view.width
                record: modelData
                previewFile: root.previewSource(modelData.thumb, root.previewRevision)
                onRecordChanged: root.requestPreview(record ? record.thumb : "")
                selected: root.selectedId === modelData.id
                onClicked: {
                  root.selectedId = modelData.id
                  list.currentIndex = index
                }
              }

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.space(40)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: root.rows.length === 0 && !root.busy
                textFormat: Text.PlainText
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                text: {
                  if (root.loadError !== "")
                    return root.loadError
                  if (root.query !== "")
                    return "Nothing matches “" + root.query + "”"
                  if (root.scope === "updates")
                    return "Every installed plugin is up to date."
                  if (root.scope === "installed")
                    return "No third-party plugins installed yet.\nBrowse the marketplace to add one."
                  return "Nothing to show."
                }
              }
            }
          }

          // detail
          Detail {
            Layout.fillWidth: window.detailTakesOver
            Layout.preferredWidth: window.detailTakesOver
              ? -1 : Math.min(Style.space(400), window.width * 0.38)
            Layout.fillHeight: true
            visible: (window.wide || window.detailTakesOver) && !root.showSettings
            record: root.selected
            jobRunning: root.jobRunning
            previewFile: root.previewSource(root.selected ? root.selected.shot : "", root.previewRevision)
            onRecordChanged: root.requestPreview(record ? record.shot : "")
            showBack: window.detailTakesOver
            onBack: root.selectedId = ""
            onAct: function (verb) { root.requestAction(verb, root.selected) }
          }

          // Settings replaces the whole body rather than sitting beside it:
          // on a narrow window there is no room for a fourth column, and it is
          // a mode you leave, not a pane you glance at.
          Settings {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.showSettings
            binDir: root.binDir
            pluginId: root.pluginId
          }
        }

        // ───────────────────────────────── job strip
        JobStrip {
          Layout.fillWidth: true
          visible: root.job !== null
          job: root.job
          log: root.jobLog
          onDismiss: root.dismissJob()
        }
      }

      // ───────────────────────────────── views drawer
      // The inline column needs 180px it does not have on a tiled window, so
      // below that threshold the same switcher opens over the list instead.
      Item {
        anchors.fill: parent
        visible: root.sidebarOpen && !window.showSidebar && !root.showSettings

        Rectangle {
          anchors.fill: parent
          color: Color.menu.scrim
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.sidebarOpen = false
          }
        }

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Math.min(Style.space(230), parent.width * 0.7)
          color: Color.menu.background
          border.width: Style.normalBorderWidth
          border.color: Util.alpha(Color.menu.border, Style.normalBorderAlpha)

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {}
          }

          Sidebar {
            anchors.fill: parent
            anchors.margins: Style.spacing.panelPadding
            scopes: root.scopes
            categories: root.categories
            scope: root.scope
            category: root.category
            onScopeChosen: function (key) { root.setScope(key) }
            onCategoryChosen: function (name) { root.chooseCategory(name) }
          }
        }
      }

      // ───────────────────────────────── confirmation
      Confirm {
        id: confirmSheet
        anchors.fill: parent
        visible: root.pendingAction !== null
        action: root.pendingAction
        binDir: root.binDir
        onConfirmed: root.confirmAction()
        onCancelled: root.pendingAction = null
      }
    }
  }
}
