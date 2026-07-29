# GarminDataFieldService Plugin for Loop

A Loop service plugin that sends real-time glucose, insulin-on-board (IOB), carbs-on-board (COB), basal rate, and predicted glucose to Garmin devices over Bluetooth. Works with the published Trio Datafield or SwissAlpine datafields from the Garmin Connect IQ store—no custom Connect IQ app development required.

**Disclaimer:** This is a DIY project intended for personal use by Loop users comfortable building from source. It is **NOT** a medical device and **should not** be used to make any medical decisions or treatments. The code comes with **no guarantees of reliability** or accuracy, and its use is entirely at the risk of the user. This service has been **only partially tested** and could cause Loop to crash, though this did not occur during initial testing. The creators and contributors take no responsibility for any outcomes resulting from the use of this plugin.

## How It Works

GarminDataFieldService implements Loop's `RemoteDataService` protocol to push loop data to Garmin devices. It sends data via **dosing-decision uploads**, which fire automatically every loop cycle (~5 minutes). This ensures consistent, frequent device updates even if you disable glucose uploads to other services.

When the "Upload Readings" toggle is enabled, the plugin opportunistically processes glucose uploads for faster updates and trend arrows, but this is optional – the dosing decision alone provides all necessary data.

The plugin sends a Trio-format JSON message over Bluetooth (via Garmin ConnectIQ SDK 1.8 and Garmin Connect Mobile), making it compatible with the **published Trio Datafield** and **SwissAlpine datafields** available in the Garmin Connect IQ store. The datafield works entirely offline; no internet connection is required.

## Requirements

- **Garmin Device:** Any device supported by the Trio Datafield. The Edge bike computers (Edge 530, 540, 840, Explore 2, 1030/1030 Plus, 1040, 1050, 550, 850, MTB) are all listed as compatible, along with most recent watches. See the [store listing](https://apps.garmin.com/apps/8a418d15-e681-4774-9530-e70be03ec330) for the full device list.
- **Garmin Connect Mobile App:** Installed and paired with your Garmin device over Bluetooth.
- **Loop:** Built from [LoopWorkspace](https://github.com/LoopKit/LoopWorkspace) with this plugin integrated.

## Installation

### On Your Garmin Device

1. Open the **Garmin Connect Mobile** app on your iPhone.
2. Navigate to **Connect IQ Store** and search for **Trio Datafield** (or SwissAlpine if you prefer).
3. Install the datafield: [Trio Datafield (Store Link)](https://apps.garmin.com/apps/8a418d15-e681-4774-9530-e70be03ec330)
4. On your Garmin device, add the datafield to a data screen: **Connect IQ** → **Trio Datafield** → add to screen.

### On Your iPhone (Phone-Side Setup)

A pre-wired LoopWorkspace fork is available on branch `garmin`. It carries this
plugin as a submodule, the workspace and shared-scheme wiring, and the two small
Loop patches in `patches/`.

#### Option A: browser build (no Mac required)

If you have never built Loop this way, follow the standard
[LoopDocs browser build](https://loopkit.github.io/loopdocs/gh-actions/gh-overview/)
setup first — you need a GitHub account, an Apple Developer Program membership,
and the one-time secrets/certificates steps. Then bring the `garmin` branch into
your own fork as outlined below.

**Note:** GitHub allows only one fork per repository per account, so if you
already have a LoopWorkspace fork you cannot also fork this one. Bring the
branch into the fork you already have instead. Entirely in the browser:

1. In your fork, create a new branch named `garmin`: Click the dropdown at upper left showing the current branch, and choose "View all branches."  Then click the green "New branch" button at upper right.  Name the branch `garmin` and choose `dev` as the source. 
2. Edit this URL:
   `https://github.com/YOUR-USERNAME/LoopWorkspace/compare/garmin...elnjensen:garmin` and replace `YOUR-USERNAME` with your GitHub username.  Enter that URL in a browser to create a pull request to pull the changes from the `elnjensen` garmin branch into your own. 
3. Click the green "Create pull request" button to create the pull request and merge it into your branch. 

Then run the **4. Build Loop** action with the `garmin` branch selected.
The workflow applies everything in `patches/` for you. The plugin adds no new
app identifiers, so if you have built Loop before there is nothing to
re-register.

#### Option B: local Xcode build

```bash
git clone --branch=garmin --recurse-submodules https://github.com/elnjensen/LoopWorkspace
cd LoopWorkspace
git apply patches/*.patch --whitespace=fix
xed .   # set your development team, then build to your phone
```

**Do not skip the `git apply` step.** Xcode does not apply `patches/` — only the
GitHub Actions workflow does. Without it Loop still compiles and runs, but
selecting a Garmin device will silently fail: Garmin Connect Mobile opens, and
on return to Loop nothing happens, with no error message. The command prints a
few `trailing whitespace` warnings on success; only treat it as failed if you
see `error:`.

<!--
#### Option C: integrate into your own LoopWorkspace (most complicated, use with caution)

1. Add this repo as a submodule **inside** your LoopWorkspace folder:

   ```bash
   cd LoopWorkspace
   git submodule add https://github.com/elnjensen/GarminDataFieldService.git GarminDataFieldService
   ```

2. Apply the two Loop patches (they add ~5 lines forwarding unhandled URLs as
   the `org.loopkit.Loop.didReceiveURL` notification, and the `gcm-ciq` entry
   in `LSApplicationQueriesSchemes` so the ConnectIQ SDK can launch Garmin
   Connect Mobile):

   ```bash
   cd Loop
   git apply ../GarminDataFieldService/patches/0001-loop-forward-unhandled-urls.patch
   git apply ../GarminDataFieldService/patches/0002-loop-allow-gcm-ciq-query-scheme.patch
   cd ..
   ```

3. Wire the plugin project into the workspace and shared scheme:

   ```bash
   git apply GarminDataFieldService/patches/0003-loopworkspace-add-plugin-project.patch
   ```

   This patch tracks a moving upstream, so on a newer LoopWorkspace it may fail
   with `patch does not apply`. If so, make the two edits by hand — they are
   small. In `LoopWorkspace.xcworkspace/contents.xcworkspacedata` add a
   `FileRef` whose location is
   `group:GarminDataFieldService/GarminDataFieldService.xcodeproj`, and in
   `LoopWorkspace.xcworkspace/xcshareddata/xcschemes/LoopWorkspace.xcscheme` copy
   an existing plugin's `BuildActionEntry`, changing the buildable name to
   `GarminDataFieldServiceKitPlugin.loopplugin`, the blueprint name to
   `GarminDataFieldServiceKitPlugin`, the referenced container to the path above,
   and the `BlueprintIdentifier` to the `GarminDataFieldServiceKitPlugin`
   `PBXNativeTarget` UUID from
   `GarminDataFieldService/GarminDataFieldService.xcodeproj/project.pbxproj`.
   The entry must come **before** the Loop app target, since Loop's build copies
   the already-built plugin.

No changes to the Loop target itself are needed: Loop's existing
`copy-plugins.sh` build phase discovers the built `.loopplugin` bundle and
copies it (and its embedded frameworks, including ConnectIQ) into the app
automatically.

If you ever need to regenerate the Xcode project (e.g. after adding source
files), use the helper script — it assigns fresh target UUIDs and
automatically re-patches the workspace scheme to match:

```bash
gem install xcodeproj
ruby Scripts/generate_project.rb
```

Then build and run Loop on your iPhone as usual. The plugin will be included
automatically.

-->

## Setup in Loop

1. Open **Loop** → **Settings** → **Services** → **Add Service** → **Garmin Service**.
2. Tap **Connect Garmin Devices…** to open Garmin Connect Mobile and select which devices to pair. Loop will re-open automatically with your selection.
3. **Choose Connect IQ App:** Select the target to send to (default: Trio Datafield;
   also SwissAlpine, the Loop Graph datafield, the Trio and SwissAlpine **watch
   faces**, or a custom Connect IQ app UUID).

   All of these consume the same message format, so the phone side is identical
   for every option — only the UUID differs. Note the lifecycle difference: a
   **datafield** only updates while an activity is recording, whereas a **watch
   face** updates whenever it is displayed, so it needs no activity. The watch
   face UUIDs come from Trio's published values and are **untested here** — if
   you try one, please report whether it works.
4. **Configure Display Values:** Choose what appears in the datafield's two configurable slots:
   - Value 1: COB or ISF (Insulin Sensitivity Factor)
   - Value 2: Basal rate or Eventual BG
   (Glucose with trend arrow and IOB are always shown.)
5. Tap **Add Service** to finish. Loop only starts feeding data to the service at
   this point, so data will not reach your Garmin device until you do this.
6. **Resend Latest Data:** re-open the service settings and tap this to send the
   most recent loop data immediately. This action only appears after the service
   has been added, for the reason above.
7. **Send Data to Garmin** (toggle at the top): unlike always-on uploaders such as Nightscout, you probably only want this service active during a ride or run. Turn it off between activities to silence all Garmin communication; Loop keeps collecting data in the background, so turning it back on updates the device right away. The switch takes effect immediately (no need to tap Done).

## Troubleshooting

**Datafield shows old values or a red screen, and never updates — check Auto Pause first**

This is the most common cause, and it looks exactly like the plugin being broken.
A Connect IQ datafield only updates while the activity timer is *running*. If your
device auto-pauses — which it will within seconds when you start an activity
indoors and don't move — the datafield stops updating and keeps displaying
whatever it last had, usually flagged stale. Loop reports the data as sent, because
it was: the phone delivered the message, and it cannot tell whether the datafield
ran and redrew.

Turn off **Auto Pause** for the activity profile you are testing with (on Edge
devices: Activity Profiles → your profile → Timer → Auto Pause → Off), or use an
indoor/trainer profile, or move the device. With the timer genuinely running,
"Resend Latest Data" updates the display immediately.

**Device shows "Not Connected" or displays "—"**
- Open **Garmin Connect Mobile** and confirm Bluetooth is connected to your Garmin device.
- Restart Bluetooth on both ends if pairing seems stale.

**Datafield shows stale data or no data**
- Confirm you finished setup by tapping **Add Service**. Loop delivers no data to
  the service until then, and "Resend Latest Data" cannot help.
- After the service is added Loop backfills recent data right away, but a newly
  paired device is not sendable until Bluetooth characteristic discovery
  finishes, so allow a few seconds. After that, data flows on ~5-minute loop cycles.
- Confirm the Trio Datafield is installed on your Garmin device and selected on a data screen.
- Verify in Loop settings that the Connect IQ app UUID matches what you installed (default is Trio Datafield).
- Check that Loop is running and completing dosing cycles normally (check the Loop log).

**Garmin Connect Mobile fails to launch**
- Ensure the app is installed on your iPhone.
- Confirm the Info.plist patch adding `gcm-ciq` to `LSApplicationQueriesSchemes` was applied.

## Data Sent

Each loop cycle, the plugin sends:

- **Glucose (BG):** Current blood glucose and trend arrow direction
- **IOB:** Insulin on board
- **COB:** Carbs on board
- **Basal Rate:** Active temp basal rate, falling back to the scheduled basal rate
- **Eventual BG:** Predicted glucose (last element of the prediction curve)
- **Timestamp & Units:** Data age and mg/dL or mmol/L (follows Loop's setting)

Historical glucose is included for graphing on compatible Connect IQ apps.

## Credits

- **[Trio Project](https://github.com/nightscout/Trio)** (MIT): the Garmin message format and device-readiness/send logic are ported or adapted from Trio's Garmin support, and the published Trio Datafield and SwissAlpine Connect IQ apps this plugin drives come from the Trio community (datafield by Pierre, watchfaces by Ivan Valkou and the SwissAlpine/AAPS authors).
- **[janvv/GarminService](https://github.com/janvv/GarminService)** (BSD 2-Clause): the original Loop-Garmin plugin that inspired me to create this, and showed this approach can work; this project reuses its plugin structure and a version of its service icon (the bike-handlebars illustration).
- **[NightscoutService](https://github.com/LoopKit/NightscoutService)** / Tidepool Project (BSD 2-Clause): the canonical Loop service-plugin template this project's targets and HKUnit extension are taken from.
- **Garmin Connect IQ Companion App SDK for iOS** (v1.8.0): Garmin's official SDK for phone-to-device communication.

See the [LICENSE](LICENSE) file for full attribution details.

## License

MIT — see [LICENSE](LICENSE), which also lists the third-party works this project incorporates. This project is provided "as-is" without any warranties or guarantees; the authors assume no responsibility for any outcomes or damage resulting from its use.
