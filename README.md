# SwingLab recorder, the Flutter app

An Android app that connects to the SwingLab bat sensor over Bluetooth, records each shot between Start and Stop, and saves every reading as a CSV file in a folder per shot type.

The sensor, its circuit and its firmware are in [Cric-Pro-Hardware](https://github.com/gaurav3611/Cric-Pro-Hardware). The web dashboard is [Cric-Pro-FE](https://github.com/gaurav3611/Cric-Pro-FE).

## What it does

- **Finds and connects** to the bat. Only devices that advertise the SwingLab service are listed. It works with the bat running stage 5 or stage 8 of [Cric-Pro-Hardware](https://github.com/gaurav3611/Cric-Pro-Hardware).
- **Shows live readings**: acceleration and rotation on all three axes, bat speed, total acceleration, and readings per second.
- **Records between Start and Stop.** Every reading is kept, with the time the phone received it and the time since Start.
- **Saves each shot as a CSV file**, named by its type and numbered:

  ```
  recordings/
    pull_shot/pull_shot_001.csv
    pull_shot/pull_shot_002.csv
    drive_shot/drive_shot_001.csv
    index.csv              one line per recording: type, how it was found, readings, duration, status
  ```

- **Keeps what was recorded if the sensor disconnects** in the middle, marked as interrupted in `index.csv`.
- **Shares files** to Drive, email or WhatsApp, one at a time or all at once, and deletes them.
- **Has a simulated bat**, for trying it without a sensor. Its files start with `sim_`.

## How the shot type is found

You choose the type before pressing Start, or leave it on **Detect automatically**. The automatic choice is **a first guess from fixed rules, not a trained or tested classifier**, because no labelled recordings exist yet:

| The recording shows | Guess |
|---|---|
| Fewer than 10 readings | unknown |
| Peak bat speed under 20 km/h | defensive shot |
| Faster, turning to the leg side at the peak | pull shot |
| Faster, turning to the off side | cut shot |
| Faster, neither | drive shot |

To build a real classifier, record many shots of each type with the type chosen by hand. The files are then named by their true type, and `index.csv` shows how often the guess agreed. A trained model can later replace `classify` in `lib/protocol.dart`.

## The CSV columns

One row per reading, about 50 a second.

| Column | Meaning |
|---|---|
| `sample_index` | 0, 1, 2 and so on |
| `timestamp_iso`, `timestamp_ms` | When the phone received the reading. The sensor sends no time of its own. |
| `elapsed_ms` | Milliseconds since Start |
| `ax_g`, `ay_g`, `az_g` | Acceleration in g |
| `gx_dps`, `gy_dps`, `gz_dps` | Rotation in degrees per second |
| `accel_total_g`, `speed_kmh` | Total acceleration, and bat speed by the dashboard's formula |
| `ax_raw` to `gz_raw`, `temp_raw` | The seven numbers exactly as the sensor sent them |

## Build and install

You need Flutter, the Android SDK and Java 17 or newer.

```bash
git clone https://github.com/gaurav3611/mobile_app_swing.git
cd mobile_app_swing
flutter pub get
flutter test                       # the logic: packet, shot guess, CSV, file names
flutter build apk --release        # makes build/app/outputs/flutter-apk/app-release.apk
```

Install it on the phone in one of two ways:

- **With a USB cable:** switch on Developer options and USB debugging on the phone, plug it in, then `flutter install` or `adb install build/app/outputs/flutter-apk/app-release.apk`.
- **Without a cable:** copy `app-release.apk` to the phone, open it in the Files app, and allow installing apps from that source.

On first use the phone asks to allow "Nearby devices". Allow it, or the app cannot find the sensor.

## Where the files are

On the phone: `Android/data/com.swinglab.swinglab_recorder/files/recordings/`. Newer Android versions hide that folder from the Files app, so use **Share** or **Share all files** in the app, or connect the phone to a computer by USB and open the same folder there.

## Things to know

- **The Bluetooth package, flutter_blue_plus, is free for personal, educational and nonprofit use only.** A company selling or using this app for profit needs its commercial licence, or the Bluetooth code must move to a BSD-licensed package such as flutter_reactive_ble.
- **Android only.** An iPhone version needs Xcode on a Mac, which this project has not been built with.
- **CSV only**, no `.xlsx`. Excel opens CSV files directly.
- **The release APK is signed with the debug key.** That is fine for installing it yourself, not for the Play Store.
- **Keep the app on screen while recording.** Recording with the screen off was not built or tested.
- **Tested by the owner on an Android phone**, after the unit tests and the Android build passed.
