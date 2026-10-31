# Local signing setup

Signing identifies the Apple development team and installed app. Configure it separately
from the app icon and display name.

## First installation

1. Add your Apple account in Xcode's **Settings → Apple Accounts**.
2. Select the **HouseCapture** target and open **Signing & Capabilities**.
3. Enable **Automatically manage signing** and select your team.
4. Choose a unique bundle identifier for your fork, such as `com.yourname.housecapture`.
5. Select your connected device and Run. Follow device pairing, Developer Mode and
   certificate trust prompts if requested.

## Preserve settings when regenerating the project

Create `Signing.local.xcconfig` next to `project.yml`:

```xcconfig
HOUSE_CAPTURE_BUNDLE_ID = com.yourname.housecapture
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Use the identifier and team already selected in Xcode. The team ID is the value of
**Development Team** in the target's Build Settings; it is not your Apple account email.

The tracked `Signing.xcconfig` loads this optional, Git-ignored file. Without it,
the project uses the original `com.wesbos.housecapture` identifier and no team.
Do not commit your local signing file.

From `apps/house-capture`, run:

```sh
xcodegen generate
open HouseCapture.xcodeproj
```

Both Debug and Release load the signing configuration. When adding another build
configuration, add it to the target's `configFiles` mapping in `project.yml`:

```yaml
configFiles:
  Debug: Signing.xcconfig
  Release: Signing.xcconfig
  # Add other configurations here when they exist in the project.
```

Keep the bundle identifier of an installed development app to update it and retain its
data. Use a different identifier from the official app to keep both installed. Changing
the icon or display name alone does not create a separate installation.
