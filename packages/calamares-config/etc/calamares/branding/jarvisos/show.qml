import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Rectangle {
        anchors.fill: parent
        color: "#1a1a2e"

        Column {
            anchors.centerIn: parent
            spacing: 30

            Text {
                text: "Welcome to JARVIS OS"
                font.pixelSize: 42
                font.bold: true
                color: "#FFFFFF"
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                text: "AI-Powered Operating System"
                font.pixelSize: 24
                color: "#4CAF50"
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                text: "Installing your system, please wait..."
                font.pixelSize: 18
                color: "#AAAAAA"
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                Repeater {
                    model: 3
                    Rectangle {
                        width: 12
                        height: 12
                        radius: 6
                        color: "#4CAF50"
                        opacity: 0.3
                        
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            NumberAnimation { 
                                to: 1.0
                                duration: 600
                            }
                            NumberAnimation { 
                                to: 0.3
                                duration: 600
                            }
                            PauseAnimation { 
                                duration: index * 200 
                            }
                        }
                    }
                }
            }
        }
    }
}
