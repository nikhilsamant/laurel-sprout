/*
 * Charge limit page for Lomiri System Settings -- Xiaomi Mi A3 (laurel_sprout).
 *
 * Pure-QML plugin (no C++/.so). It only writes the config file that
 * battery-charge-limit.service re-reads every poll; a change takes effect
 * within ~30s with no restart and no sudo. See DEVELOPMENT.md.
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

    // Hardcoded: UT is single-user and System Settings runs as "phablet".
    property string confPath: "/home/phablet/.config/battery-charge-limit"

    property int  limitValue: 80
    property bool optimiseEnabled: true
    property bool loaded: false

    // Slider stops at 95; "no limit" is the switch's job. A hand-written
    // CHARGE_LIMIT=100 still counts as off.
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
        conf.sync()   // this file is polled/watched, so flush promptly
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

                // Greyed out rather than hidden when the switch is off.
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

                        // Snap to 5% steps.
                        onValueChanged: root.limitValue = Math.round(value / 5) * 5

                        // Save once the finger lifts, not on every drag pixel.
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
