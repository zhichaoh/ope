import QtQuick 2.11
import QtQuick.Controls 2.4
import QtQuick.Controls.Material 2.3
import QtQuick.Controls.Universal 2.3
import QtQuick.Controls.Styles 1.4
import QtQuick.Controls.Imagine 2.3
import QtQuick.Layouts 1.3

import com.openprisoneducation.ope 1.0
import "App.js" as App

ApplicationWindow {
    visible: true;
    visibility: "Windowed"; // "FullScreen"
    flags: (Qt.Window) ; // Qt.WindowStaysOnTopHint
    id: main_window
    objectName: "main_window"

    width: 900;
    height: 600;

    title: qsTr("OPE - Offline LMS");

    Page {
        id: appPage
        anchors.fill: parent;
        Rectangle {
            color: "#bb0000"
            anchors.fill: parent;

            Column {
                anchors.fill: parent;

                Text {
                    text: "APP NOT CREDENTIALED!";
                    font.pointSize: 35;
                    horizontalAlignment: Text.AlignHCenter;
                    verticalAlignment: Text.AlignVCenter;
                    font.bold: true;
                }

                Text {
                    text: 'You need to run the credential app to link to canvas and apply security settings';
                }
            }
        }
    }

}
