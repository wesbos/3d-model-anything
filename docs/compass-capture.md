# Compass capture and reconstructed directions

The iOS app can record compass observations during a LiDAR room scan and carry them into reconstruction. Labels describe the outward normal of a wall or window: the direction you face looking through it from inside. These are sensor estimates, not surveyed bearings.

## Capture

**Record compass directions** is off by default for every new capture session, including sessions on phones that already granted Location permission. Enable it before starting a room or while paused. With it off, no compass/location updates start, no Location permission is requested, and captures without readings omit compass metadata. Turning it off stops new readings and photo associations; observations already recorded remain in exports. The existing scanning and reconstruction flow works without enabling this feature.

Location While Using the App lets Core Location correct magnetic north to true north. Coarse location is sufficient; the app never saves geographic coordinates. Denied permission, an unavailable fix or invalid true heading produces explicitly magnetic observations instead.

The recorder keeps up to two observations per second, paired to the nearest AR pose within 150 ms. It buffers two seconds of fresh poses while tracking is stable and recording is active. Pausing and room/session completion stop the sensors; recovery clears pose input. Readings are saved with the room/session manifest, like the photo index.

Compass sensors and optional mesh/depth reconfiguration wait until tracking is stable. Saved diagnostics and the attached console report camera/location authorization, tracking state, landmark counts and sampled camera brightness. Brightness diagnostics store aggregate values only, not image pixels. `cameraAuthorization = 3` means camera access is authorized; `locationAuthorization = 4` means Location While Using the App.

`CLHeading` angles describe the portrait top edge, which is not the rear camera's viewing direction in an upright scan. The recorder transforms the three-dimensional magnetic field using `ARCamera.viewMatrix(for: .portrait).inverse`, projects onto the session horizontal plane, and applies true-minus-magnetic declination when available. Original readings and transforms stay inspectable. Compass updates do not rotate live RoomPlan geometry.

## Export

Additive fields retain `house-capture/5`:

- `manifest.compass`: `compass/headings.json`, when observations exist.
- `manifest.compassSampleCount`: observation count.
- `PhotoRecord.compassTimestamp`: linked observation timestamp, within one second of the photo.

An observation stores `room`, monotonic `timestamp`, `frameTimestamp`, Unix `recordedAt`, `magneticHeading`, optional `trueHeading`, `headingAccuracy`, `magneticField`, column-major `cameraTransform` and `deviceTransform`, `poseTimeOffsetSeconds`, `reference` (`true`/`magnetic`), optional unit `northInSession`, optional rear `cameraBearing`, and optional `rejection` reason. Negative accuracy, weak horizontal field or unsynchronized pose yields no usable north. Readings above 25° accuracy are retained with `lowAccuracy`.

Room-only sharing filters observations by room while retaining original indices/timestamps. Import preserves them. Discarding a room during capture removes its observations. Old exports without compass data remain usable.

## Reconstruction

Run `bundle_to_room.py` or `house_to_rooms.py` as usual. The converter uses synchronized readings with reported accuracy at most 25°. It never averages true north with magnetic north, prefers true north once supported by three observations, and requires three readings spanning one second. Circular averaging handles 359°/0°. It requires 70% agreement within 20° and combines the largest retained sensor error with angular spread. Spread over 15° or combined uncertainty over 25° suppresses direction labels.

Converted `compass.samples` retains the original observations in **session coordinates**. An `aligned` result has `compass.north` in **room coordinates**, transformed by `transform.worldToRoom`, plus quality and provenance. Walls/openings get outward `facing` bearings. Photos with a valid linked observation get `compass` bearings. House imports also save north in **house coordinates** under `housePlacement.compass` and the index entry. Bearings run clockwise from the stated north reference.

Keep the converted layout including `compass` when implementing the rebuilt `RoomModule`. The standard viewer reads `BuiltRoom.layout.compass` to display 3D wall/window labels, a north indicator, and plan bearings. If geometry is rotated again, rotate north with it. Missing/uncertain readings remain unlabeled. Model axes do not establish geographic direction. Surface bearing numbers remain valid when geometry and north rotate together.

For immediate inspection before detailed reconstruction, run the viewer and open `/inspect.html`. Select the converted `room.json` with **Open room JSON**, then switch between **3D** and **Floor plan**. This shows the measured room/furniture bounds, recorded north, wall/window bearings and uncertainty. File selection stays in the browser and does not upload the scan. Detailed reconstruction still uses the agent workflow.

## Device validation

Simulator compilation cannot validate the compass/LiDAR combination. Before relying on a tour scan, compare a known wall/window bearing with the camera readout at several phone tilts, then review exported directions after reconstruction and after a room rotation. Also check denied Location permission, magnetic fallback, pause/resume, interruption recovery and room-only export/import on an iPhone.

Indoor magnetic fields can bias even consistent readings. Displayed uncertainty reflects sensor-reported accuracy and observed disagreement; it cannot establish that nearby metal introduced no systematic error.

Apple references: [CLHeading](https://developer.apple.com/documentation/corelocation/clheading), [true heading](https://developer.apple.com/documentation/corelocation/clheading/trueheading), [heading accuracy](https://developer.apple.com/documentation/corelocation/clheading/headingaccuracy), [camera view matrix](https://developer.apple.com/documentation/arkit/arcamera/viewmatrix(for:)).

## Native review

In the native saved-scan 3D/mesh viewer, open the filter menu and enable **Recorded north** (off by default). Valid recorded observations produce an orange north arrow for each visible room, labeled true/magnetic and estimated uncertainty. North receives the same session-to-house rotation as the mesh. Scans without usable readings leave the toggle disabled; review never requests Location.
