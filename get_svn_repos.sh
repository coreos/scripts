#!/bin/sh

#Temp Hack to get SVN repos for ebuilds that haven't switched to tar balls or getting code via SVN.

 # O3D selenium tests
svn checkout http://o3d.googlecode.com/svn/trunk/googleclient/third_party/selenium_rc@178 ../third_party/autotest/files/client/site_tests/graphics_O3DSelenium/O3D/third_party/selenium_rc
svn checkout http://src.chromium.org/svn/trunk/src/o3d/tests/selenium@44717 ../third_party/autotest/files/client/site_tests/graphics_O3DSelenium/O3D/o3d/tests/selenium
svn checkout http://src.chromium.org/svn/trunk/src/o3d/samples@46579 ../third_party/autotest/files/client/site_tests/graphics_O3DSelenium/O3D/o3d/samples
svn checkout http://o3d.googlecode.com/svn/trunk/googleclient/o3d_assets/tests@155 ../third_party/autotest/files/client/site_tests/graphics_O3DSelenium/O3D/o3d/o3d_assets/tests
svn checkout http://google-gflags.googlecode.com/svn/trunk@29 ../third_party/autotest/files/client/site_tests/graphics_O3DSelenium/O3D/o3d/third_party/gflags
svn checkout https://cvs.khronos.org/svn/repos/registry/trunk/public/webgl/sdk/tests@11002 ../third_party/autotest/files/client/site_tests/graphics_WebGLConformance/WebGL
