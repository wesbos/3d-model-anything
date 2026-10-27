# Release status

## Public source and demo

This repository starts with a new history. Only the office reconstruction is included. Its earlier modeling layers remain source dependencies of the latest version. House layout, private rooms, original scan meshes, photo collections, recordings and personal signing settings are excluded.

`docs/public-assets.json` records SHA-256 hashes for every distributed data file. `python3 tools/audit-public.py` checks tracked files against that boundary before deployment. Review and update the manifest explicitly when adding public assets. This is a release boundary check, not a general secret scanner or a substitute for reviewing image content.

Validated locally:
- Clean dependency install and TypeScript/production viewer build.
- Office rendering and browser console check.
- Skill frontmatter validation and seven synthetic house-export/import tests.
- Release iOS Simulator build with signing disabled.

## iPhone distribution

The app's display name is **3D Model Anything**. `house-capture/5`, existing serialized keys, the Xcode target and `com.wesbos.housecapture` bundle identifier remain unchanged for compatibility. Contributors select their own signing team in Xcode.

Version 1.0 is [live on the App Store](https://apps.apple.com/app/3d-model-anything/id6825843398), available free. Public availability was verified on October 27, 2026.

For future TestFlight/App Store releases:
- Verify the configured public privacy/support URLs and GitHub Issues support link.
- Complete store pricing and reviewer contact details.
- Configure distribution signing and App Store Connect.
- Complete real-device capture, export/import, tracking recovery and accessibility checks.
- Capture reviewed screenshots using only the approved office or synthetic data.
- Archive for iOS, run `apps/house-capture/release/validate.py`, and validate/upload in Xcode Organizer.

See the detailed checklist in `apps/house-capture/release/`. No physical-device or App Review success is claimed by the simulator build.
