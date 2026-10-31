# Development icon and scheme

Development builds use a blue cube with a **DEV** label and the display name
**3D Model Dev**. Release builds retain the original icon and **3D Model Anything** name.

| Configuration | Icon       | Display name      | Optimization |
| ------------- | ---------- | ----------------- | ------------ |
| Debug         | AppIconDev | 3D Model Dev      | Debug        |
| Development   | AppIconDev | 3D Model Dev      | Release      |
| Release       | AppIcon    | 3D Model Anything | Release      |

## Install a development build

From `apps/house-capture`, run `xcodegen generate` and open `HouseCapture.xcodeproj`.
Select the **HouseCaptureDev** scheme, select your device, and Run. This scheme uses
the optimized **Development** configuration for physical scanning. The **HouseCapture**
scheme uses Release for running and archiving.

This feature changes branding and adds a build configuration; it does not configure
your Apple team or change your bundle identifier. Keep your existing development
identifier when updating an installed app. Production and development apps need
distinct identifiers to coexist on a device.

If your project uses per-configuration signing files, map **Development** to the same
local signing file as your other development builds. For example, when combining this
feature with the separate local-signing implementation, add
`Development: Signing.xcconfig` under the target's `configFiles` in `project.yml`.

## Customize the development icon

The production asset remains in `HouseCapture/Assets.xcassets/AppIcon.appiconset`.
The development asset is in `HouseCapture/Assets.xcassets/AppIconDev.appiconset`.

Edit `release/generate-dev-icon.swift`, then run from `apps/house-capture`:

```sh
swift release/generate-dev-icon.swift
```

The generator writes a 1024×1024 opaque PNG into the development icon set only.
The display names and icon selection are defined in `project.yml`; `Info.plist`
reads `APP_DISPLAY_NAME` from the selected configuration.
