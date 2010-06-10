#!/bin/sh

#Temp Hack to get SVN repos for ebuilds that haven't switched to tar balls or getting code via SVN.

svn checkout http://mozc.googlecode.com/svn/trunk@24 src/third_party/ibus-mozc/files
svn checkout http://google-breakpad.googlecode.com/svn/trunk@598 src/third_party/google-breakpad/files
svn checkout http://shflags.googlecode.com/svn/tags/1.0.3@137 src/third_party/shflags/files
svn checkout http://shunit2.googlecode.com/svn/tags/source/2.1.5@294 src/third_party/shunit2/files
svn checkout http://src.chromium.org/svn/trunk/src/base@36775 src/third_party/chrome/files/base
svn checkout http://src.chromium.org/svn/trunk/src/build@36775 src/third_party/chrome/files/build
svn checkout http://o3d.googlecode.com/svn/trunk/googleclient/third_party/vectormath@166 src/third_party/vectormath
svn checkout http://v8.googlecode.com/svn/trunk@4565 src/third_party/v8
svn checkout http://gyp.googlecode.com/svn/trunk@824 src/third_party/gyp/files
