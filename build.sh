#!/bin/sh

set -e
set -x

pod update

xcodebuild -workspace MatrixSDK.xcworkspace/ -scheme MatrixSDK -sdk iphonesimulator  -destination 'name=iPhone 4s'
