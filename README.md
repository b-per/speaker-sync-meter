# Speaker Sync Meter

Speaker Sync uses one Mac microphone to estimate the residual delay between a Google Nest and a Sonos on AirPlay while they play in the same Music Assistant group. It suggests a new AirPlay **Audio synchronization delay correction** in milliseconds. The app runs locally and holds microphone audio in memory during measurement.

On my setup, the measured gap between a Google Nest and a Sonos grouped in Music Assistant went from about **48 ms to 4 ms** after applying the suggested adjustment. Your mileage may vary with speaker placement, room acoustics, and how stable the group’s playback timing is.

## Download for macOS

Download `Speaker-Sync-Meter-macOS-universal.zip` from the [latest release](https://github.com/b-per/speaker-sync-meter/releases/latest). Unzip it and open **Speaker Sync.app**. The archive includes the calibration WAV and the script for serving it to Music Assistant. The app supports Apple Silicon and Intel Macs with macOS 13 or later.

The app is ad-hoc signed. Apple notarization is unavailable for this build, so macOS may show a Gatekeeper alert on first launch. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

### Build from source

Run `./build.sh` with the Xcode Command Line Tools installed. This creates `build/Speaker Sync.app` and `build/Speaker Sync Calibration.wav`. Open the app in Finder or run `open "build/Speaker Sync.app"`. The app targets macOS 13 or later.

Run `./build.sh --release` to build the universal ZIP under `build/release`.

## Play the calibration track

If Music Assistant runs on a separate device on the same network, open Terminal in the unzipped folder or the source checkout and run `python3 serve-track.py`. In Music Assistant, open **Tracks → Add via URL** and paste the address the script prints. Leave the script running while you measure. It serves the WAV for one hour by default. Run it again to reuse the same address as long as the Mac’s IP address stays the same. [Music Assistant’s Add via URL instructions](https://www.music-assistant.io/music-providers/builtin/#adding-items)

You can also copy the four-minute WAV to a folder indexed by Music Assistant and open it via **Browse**. [Music Assistant Local Files setup](https://www.music-assistant.io/music-providers/local-files/)

## Measure and adjust

1. Put the Mac midway between the speaker drivers if you want to minimize the difference in sound travel time. Put it at your usual listening position if that is where you want the sounds to arrive together. Each metre of unequal distance adds about 2.9 ms to the measured difference.
2. Play **Speaker Sync Calibration** on the same two-speaker group and protocols you use for listening. Start with both speakers at a comfortable, roughly equal loudness.
3. Enter the AirPlay correction currently set in Music Assistant. The app starts at `40` ms, so check this field, even if you have never adjusted the Sonos. Allow microphone access when macOS asks. To use the Mac’s built-in mic, select it in **System Settings → Sound → Input** before starting. Use Standard Mic Mode if the system offers a choice.
4. Follow the three six-second captures in the app. Record both speakers first, then Nest alone, then Sonos alone. Change the individual volumes or mute controls while both devices stay grouped and the track keeps playing. Keep the Mac in one place. If the track ends, the speakers reconnect, or you change the playback position, start a new measurement.
5. Restore both volumes. Apply the suggested setting on the Sonos AirPlay output in Music Assistant and repeat the measurement. A positive change makes the Sonos play later. For example, if the Sonos arrives 3 ms early with an existing correction of +40 ms, try +43 ms. See the [Music Assistant AirPlay player settings](https://www.music-assistant.io/player-support/airplay/).

## How it works

The calibration track repeats a short broadband sweep. The app correlates the mic signal with that sweep and averages the response over multiple pulses. The two solo samples identify each speaker's acoustic response, including nearby reflections. The analyzer fits shifted and scaled copies of those responses to the **both-speakers** recording. The continuous mic timeline constrains that fit and helps identify which speaker arrived first. The app checks the fit on both halves of the combined recording and asks for a retry if the signals are weak, inconsistent, or ambiguous.

The measurement targets steady differences of up to roughly 120 ms and focuses on the last few milliseconds of adjustment. The app displays the estimated delay to a tenth of a millisecond. Accuracy in the room depends on speaker placement, reflections, relative loudness, and each speaker’s timing stability. If the arrivals are too close to separate, the app can report overlap when the solo samples and the combined recording agree.

The app uses [Apple AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode) and [Accelerate cross-correlation](https://developer.apple.com/documentation/accelerate/vdsp_convd). The [Sendspin sync-test tool](https://www.sendspin-audio.com/build/guide/testing/#measure-synchronization) measures two separate sound-card inputs. The one-mic fitting code lives in `Sources/Calibration.swift`, independent of the macOS window and microphone capture so it can be reused in a future iPhone app.

Run `./build.sh --test` to check signed delays and error handling with synthetic recordings at 44.1 and 48 kHz.
