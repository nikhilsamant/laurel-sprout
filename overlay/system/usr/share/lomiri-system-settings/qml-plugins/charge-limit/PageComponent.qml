/*
 * Charge limit page for Lomiri System Settings -- Xiaomi Mi A3 (laurel_sprout).
 *
 * A pure-QML plugin: no C++ and no .so. Sixteen of the shipped plugins already
 * work this way (any .settings manifest with no "plugin" key), so nothing here
 * needs a build step -- it is data files in the overlay.
 *
 * This page only writes a config file. It has no privileges and needs none:
 * battery-charge-limit.service runs as root, re-reads that file on every poll
 * and applies the value, so a change here takes effect within
 * CHARGE_POLL_INTERVAL (30s by default) with no restart and no sudo.
 *
 * The file is deliberately a plain data file rather than a systemd
 * EnvironmentFile -- it is user-writable and consumed by a root process, so an
 * EnvironmentFile would let it set arbitrary environment on that process
 * (LD_PRELOAD being the obvious one). The service-side parser accepts only
 * CHARGE_LIMIT and CHARGE_RESUME, matched by a sed whose sole capture group is
 * [0-9]{1,3} anchored to end of line, then range-checked. See
 * battery-charge-limit.sh.
 *
 * Qt.labs.settings writes INI, so setValue("CHARGE_LIMIT", 85) produces
 *
 *     [General]
 *     CHARGE_LIMIT=85
 *
 * The [General] header simply does not match the service's pattern and is
 * ignored. Verified against the on-device GNU sed 4.9, including CRLF.
 *
 * SWITCHING THE SERVICE OFF, from an unprivileged page:
 *
 *   off -> write CHARGE_ENABLED=0. The running service reads that on its next
 *          poll, restores charging and exits 0. Restart=on-failure, so the
 *          clean exit sticks and the unit really does go inactive.
 *   on  -> rewrite the same file. battery-charge-limit.path is watching it and
 *          starts the service again.
 *
 * No polkit rule, no D-Bus service, no setuid helper -- the entire privilege
 * boundary is a file this user owns and a parser that accepts three integer
 * keys and nothing else.
 */

import QtQuick 2.12
import Qt.labs.settings 1.0
import SystemSettings 1.0
import SystemSettings.ListItems 1.0 as SettingsListItems
import Lomiri.Components 1.3

ItemPage {
    id: root
    objectName: "chargeLimitPage"

    title: i18n.tr("Charging")
    flickable: scrollWidget

    /* Hardcoded rather than derived from StandardPaths: Ubuntu Touch is
     * single-user and System Settings always runs as "phablet". The service
     * side takes CHARGE_USER_CONF= if that ever stops being true, and the two
     * defaults must agree. */
    property string confPath: "/home/phablet/.config/battery-charge-limit"

    property int  limitValue: 80
    property bool optimiseEnabled: true
    property bool loaded: false

    /* The slider deliberately stops at 95, not 100. "No limit" is what the
     * switch expresses; a slider that can also mean it would give two controls
     * for one state. The service still accepts a hand-written CHARGE_LIMIT=100
     * as "off", for people editing the file directly. */
    readonly property int minLimit: 50
    readonly property int maxLimit: 95

    Settings {
        id: conf
        fileName: root.confPath
    }

    Component.onCompleted: {
        var v = parseInt(conf.value("CHARGE_LIMIT", 80), 10)
        if (isNaN(v) || v < minLimit || v > 100)
            v = 80

        var e = parseInt(conf.value("CHARGE_ENABLED", 1), 10)
        // A hand-written CHARGE_LIMIT of 100 also means off.
        optimiseEnabled = (e !== 0) && (v < 100)

        limitValue = Math.min(v, maxLimit)
        loaded = true
    }

    function save() {
        if (!loaded)
            return
        conf.setValue("CHARGE_ENABLED", optimiseEnabled ? 1 : 0)
        conf.setValue("CHARGE_LIMIT", limitValue)
        conf.setValue("CHARGE_RESUME", Math.max(0, limitValue - 5))
        // Write now rather than on destruction: the service polls this file and
        // the .path unit watches it, so both want the change on disk promptly.
        conf.sync()
    }

    Flickable {
        id: scrollWidget
        anchors.fill: parent
        contentHeight: contentItem.childrenRect.height
        boundsBehavior: (contentHeight > root.height)
            ? Flickable.DragAndOvershootBounds : Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
            anchors { left: parent.left; right: parent.right }

            SettingsListItems.Standard {
                text: i18n.tr("Optimise Battery Charging")
                Switch {
                    id: optimiseSwitch
                    SlotsLayout.position: SlotsLayout.Trailing
                    checked: root.optimiseEnabled
                    onTriggered: {
                        root.optimiseEnabled = checked
                        root.save()
                    }
                }
            }

            ListItem {
                height: sliderColumn.height + units.gu(3)
                divider.visible: true
                highlightColor: "transparent"

                // Greyed out rather than hidden when the switch is off, so the
                // control the switch governs stays visible and the page does
                // not change height as it is toggled.
                enabled: root.optimiseEnabled
                opacity: enabled ? 1.0 : 0.5

                Column {
                    id: sliderColumn
                    anchors {
                        left: parent.left
                        right: parent.right
                        margins: units.gu(2)
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: units.gu(1)

                    Label {
                        // TRANSLATORS: %1 is a battery percentage
                        text: i18n.tr("Stop charging at %1%").arg(root.limitValue)
                    }

                    Slider {
                        anchors { left: parent.left; right: parent.right }
                        minimumValue: root.minLimit
                        maximumValue: root.maxLimit
                        value: root.limitValue
                        live: true

                        function formatValue(v) {
                            return Math.round(v / 5) * 5 + "%"
                        }

                        // Snap to 5% steps; finer granularity is meaningless
                        // against a fuel gauge that reports whole percent.
                        onValueChanged: root.limitValue = Math.round(value / 5) * 5

                        // Write once the finger lifts, not on every pixel of
                        // drag -- this file is polled, not watched.
                        onPressedChanged: if (!pressed) root.save()
                    }
                }
            }

            SettingsListItems.Standard {
                highlightWhenPressed: false
                showDivider: false
                layout.subtitle.text: root.optimiseEnabled
                    ? i18n.tr("Charging stops at %1% and resumes at %2%. At the limit the battery indicator reads \"not charging\" — the phone runs off the charger. Applies within 30 seconds.").arg(root.limitValue).arg(Math.max(0, root.limitValue - 5))
                    : i18n.tr("Charge limiting is off and the background service is stopped. The battery will charge to 100%, which is what ages a lithium cell fastest.")
                layout.subtitle.wrapMode: Text.WordWrap
                layout.subtitle.maximumLineCount: 10
            }
        }
    }
}
