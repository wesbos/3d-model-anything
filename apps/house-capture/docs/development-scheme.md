# Development scheme

Use **HouseCaptureDev** to install your local version on an iPhone or iPad. It uses
an optimized Development build for scanning and appears as **3D Model Anything Dev**
with the development icon.

## Install on your device

1. Open `HouseCapture.xcodeproj` in Xcode.
2. In the toolbar beside the Run button, select **HouseCaptureDev**.
3. Select your connected iPhone or iPad as the destination.
4. Click **Run** (▶). Xcode builds, installs and opens the app on your device.

## If HouseCaptureDev is missing

From `apps/house-capture`, generate and open the project:

```sh
xcodegen generate
open HouseCapture.xcodeproj
```

Then select **HouseCaptureDev** in the toolbar. You can also find it under
**Product → Scheme**.

Regeneration can overwrite signing settings entered only in Xcode. Preserve your
existing team and bundle identifier before regenerating, or reselect them afterward.

## If the icon or name is still unchanged

1. Confirm **HouseCaptureDev** is selected in the toolbar.
2. Open **Product → Scheme → Edit Scheme…**.
3. Click **Run** in the window's left sidebar, then the **Info** tab.
4. Set **Build Configuration** to **Development** and click **Close**.
5. Select your device and click **Run** (▶) again to install the updated app.

Building alone does not install the app. The **HouseCapture** scheme uses Release
by default and shows the original icon and name.

## App identity and signing

Keep your existing development bundle identifier when updating the app. Installing
another build with the same identifier updates that app on the device. To keep your
local app alongside the official app, use a different identifier from the official app.

The development scheme does not configure your Apple team. If you use the separate
local-signing setup, add `Development: Signing.xcconfig` under the target's
`configFiles` in `project.yml` so this configuration loads your signing settings.

## Production archives

For a production archive, select **HouseCapture** and choose **Product → Archive**.
Its Archive configuration defaults to **Release**, which keeps the original icon and
**3D Model Anything** name. If you previously edited the scheme, confirm its Archive
configuration is Release before archiving.

**HouseCaptureDev** archives use Development and include development branding.
Selecting it does not change the production scheme. Production distribution still
requires the appropriate signing and bundle identifier.
