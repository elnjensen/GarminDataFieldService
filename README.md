# GarminDataFieldService Plugin for Loop

A Loop service plugin that sends real-time glucose, insulin-on-board (IOB), carbs-on-board (COB), basal rate, and predicted glucose to Garmin devices over Bluetooth. Works with the published Trio Datafield or SwissAlpine datafields from the Garmin Connect IQ store—no custom Connect IQ app development required.

**Disclaimer:** This is a DIY project intended for personal use by Loop users comfortable building from source. It is **NOT** a medical device and **should not** be used to make any medical decisions or treatments. The code comes with **no guarantees of reliability** or accuracy, and its use is entirely at the risk of the user. This service has been **only partially tested** and could cause Loop to crash, though this did not occur during initial testing. The creators and contributors take no responsibility for any outcomes resulting from the use of this plugin.

## How It Works

GarminDataFieldService implements Loop's `RemoteDataService` protocol to push loop data to Garmin devices. Unlike earlier Garmin integrations, it sends data via **dosing-decision uploads**, which fire automatically every loop cycle (~5 minutes) and are **not gated by the CGM "Upload Readings" toggle**. This ensures consistent, frequent device updates even if you disable glucose uploads to other services.

When the "Upload Readings" toggle is enabled, the plugin opportunistically processes glucose uploads for faster updates and trend arrows, but this is optional—the dosing decision alone provides all necessary data.

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

#### Easiest: build from the pre-wired LoopWorkspace fork

A LoopWorkspace fork with everything integrated is available (branch `garmin`):

```bash
git clone --branch=garmin --recurse-submodules https://github.com/elnjensen/LoopWorkspace
cd LoopWorkspace
xed .   # open in Xcode, set your team, build to your phone
```

The fork carries this plugin as a submodule inside the workspace, the
workspace/scheme wiring, and the two small Loop patches in
`LoopWorkspace/patches/` (applied automatically by the GitHub Actions
"browser build"; for local Xcode builds apply them once with
`git apply patches/garmin_*.patch` from the LoopWorkspace folder).

#### Manual: integrate into your own LoopWorkspace

1. Clone this repo **inside** your LoopWorkspace folder:

   ```bash
   cd LoopWorkspace
   git clone https://github.com/elnjensen/GarminDataFieldService
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

#### Step 4: Build Loop

Build and run Loop on your iPhone as usual. The plugin will be included automatically.

## Setup in Loop

1. Open **Loop** → **Settings** → **Services** → **Add Service** → **Garmin Datafield**.
2. Tap **Connect Garmin Devices…** to open Garmin Connect Mobile and select which devices to pair. Loop will re-open automatically with your selection.
3. **Choose Connect IQ App:** Select the datafield to use (default: Trio Datafield; also supports SwissAlpine or a custom Connect IQ app UUID).
4. **Configure Display Values:** Choose what appears in the datafield's two configurable slots:
   - Value 1: COB or ISF (Insulin Sensitivity Factor)
   - Value 2: Basal rate or Eventual BG
   (Glucose with trend arrow and IOB are always shown.)
5. **Resend Latest Data:** Tap to test—sends the most recent loop data to your Garmin device immediately.
6. **Send Data to Garmin** (toggle at the top): unlike always-on uploaders such as Nightscout, you probably only want this service active during a ride or run. Turn it off between activities to silence all Garmin communication; Loop keeps collecting data in the background, so turning it back on updates the device right away. The switch takes effect immediately (no need to tap Done).

## Troubleshooting

**Device shows "Not Connected" or displays "—"**
- Open **Garmin Connect Mobile** and confirm Bluetooth is connected to your Garmin device.
- Restart Bluetooth on both ends if pairing seems stale.

**Datafield shows stale data or no data**
- Data flows on ~5-minute loop cycles. Allow one full cycle after setup for the first data to appear.
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
- **[janvv/GarminService](https://github.com/janvv/GarminService)** (BSD 2-Clause): the original Loop-Garmin plugin that proved the approach; this project reuses its plugin structure and its service icon (the bike-handlebars illustration).
- **[NightscoutService](https://github.com/LoopKit/NightscoutService)** / Tidepool Project (BSD 2-Clause): the canonical Loop service-plugin template this project's targets and HKUnit extension are taken from.
- **Garmin Connect IQ Companion App SDK for iOS** (v1.8.0): Garmin's official SDK for phone-to-device communication.

See the [LICENSE](LICENSE) file for full attribution details.

## License

MIT — see [LICENSE](LICENSE), which also lists the third-party works this project incorporates. This project is provided "as-is" without any warranties or guarantees; the authors assume no responsibility for any outcomes or damage resulting from its use.
