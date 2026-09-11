# Swing Analyzer build helpers. Run from ExampleApps/SwingAnalyzer.

sim := env("SIM", "iPhone 17")
device := env("DEVICE", "00008150-000A31D10CF2401C")
bundle := "com.idvorkin.swinganalyzer"
sim_app := "Build/Build/Products/Debug-iphonesimulator/SwingAnalyzer.app"
device_app := "Build/Build/Products/Debug-iphoneos/SwingAnalyzer.app"

default:
    @just --list

# Copy the bundled pose model from the package test resources (run scripts/download-models.sh first).
model:
    cp -R ../../Tests/YOLOTests/Resources/yolo26n-pose.mlpackage SwingAnalyzer/

build-sim:
    xcodebuild -project SwingAnalyzer.xcodeproj -scheme SwingAnalyzer -sdk iphonesimulator \
      -derivedDataPath Build/ -destination "platform=iOS Simulator,name={{sim}}" \
      CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD"

# Build, install, and launch on the simulator; pass a video path to auto-load it.
run-sim video="": build-sim
    xcrun simctl boot "{{sim}}" 2>/dev/null || true
    open -a Simulator
    xcrun simctl install "{{sim}}" {{sim_app}}
    xcrun simctl terminate "{{sim}}" {{bundle}} 2>/dev/null || true
    SIMCTL_CHILD_SWING_VIDEO="{{video}}" xcrun simctl launch "{{sim}}" {{bundle}}

build-device:
    xcodebuild -project SwingAnalyzer.xcodeproj -scheme SwingAnalyzer -sdk iphoneos \
      -derivedDataPath Build/ -destination "platform=iOS,id={{device}}" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration build | grep -E "error:|BUILD"

# Build, install, and launch on the connected iPhone.
run-device: build-device
    xcrun devicectl device install app --device {{device}} {{device_app}}
    xcrun devicectl device process launch --device {{device}} {{bundle}}
