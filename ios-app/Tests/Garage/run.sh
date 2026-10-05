#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -D GARAGE_TESTS \
  SubaruCompanion/Core/Database.swift SubaruCompanion/Core/AppSettings.swift \
  SubaruCompanion/Core/Backup.swift SubaruCompanion/Core/VehiclePacket.swift \
  SubaruCompanion/Core/AccountGarage.swift SubaruCompanion/Core/CloudState.swift \
  SubaruCompanion/Features/Garage.swift SubaruCompanion/Features/FuelStore.swift \
  SubaruCompanion/Features/GaragePlus.swift SubaruCompanion/Features/DTC.swift Tests/Garage/main.swift -o "$OUT/garage-tests"
"$OUT/garage-tests"
