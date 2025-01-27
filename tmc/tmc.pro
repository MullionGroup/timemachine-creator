SOURCES = main.cpp api.cpp apiprocess.cpp Exif.cpp ExifData.cpp mainwindow.cpp WebViewExt.cpp ../cpp_utils/cpp_utils.cpp
INCLUDEPATH += ../cpp_utils
HEADERS += mainwindow.h api.h apiprocess.h WebViewExt.h ../cpp_utils/cpp_utils.h
CONFIG(debug, debug|release) {
  CONFIG += console
}
QT += webkit

unix:!mac{
  QMAKE_LFLAGS += -Wl,--rpath=\\\$\$ORIGIN
  QMAKE_LFLAGS_RPATH=
}

QMAKE_MACOSX_DEPLOYMENT_TARGET = 10.6

win32:RC_FILE += tmc.rc

unix: {
  QMAKE_CXXFLAGS_RELEASE -= -O2
  QMAKE_CXXFLAGS_RELEASE += -O3

  QMAKE_LFLAGS_RELEASE -= -O1
  QMAKE_LFLAGS_RELEASE += -O3
}
