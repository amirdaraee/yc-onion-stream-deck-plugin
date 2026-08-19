param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth, ContentType = WindowsRuntime] | Out-Null
[Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime] | Out-Null
[Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristic, Windows.Devices.Bluetooth, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null

function Await($Operation, [Type]$ResultType) {
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1
  } | Select-Object -First 1
  $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  $task.Wait()
  return $task.Result
}

function FullUuid([string]$Value) {
  $clean = $Value.Trim().TrimStart('0x')
  if ($clean.Length -le 4) { return [Guid](('{0:x8}-0000-1000-8000-00805f9b34fb' -f [Convert]::ToUInt32($clean, 16))) }
  return [Guid]$clean
}

function HexBytes([string]$Value) {
  $clean = $Value -replace '[^0-9A-Fa-f]', ''
  if (!$clean -or ($clean.Length % 2)) { throw 'Packet/serial must contain complete hexadecimal bytes.' }
  [byte[]]$bytes = for ($i = 0; $i -lt $clean.Length; $i += 2) { [Convert]::ToByte($clean.Substring($i, 2), 16) }
  return $bytes
}

function Hex([byte[]]$Bytes) { return (($Bytes | ForEach-Object { $_.ToString('X2') }) -join '') }

function Crc16([byte[]]$Bytes) {
  [uint16]$crc = 0xACE1
  foreach ($byte in $Bytes) {
    for ($bit = 7; $bit -ge 0; $bit--) {
      $inputBit = (($byte -shr $bit) -band 1) -eq 1
      $top = (($crc -shr 15) -band 1) -eq 1
      $crc = [uint16](($crc -shl 1) -band 0xFFFF)
      if ($inputBit -ne $top) { $crc = $crc -bxor 0x1021 }
    }
  }
  return $crc
}

function Frame([byte[]]$Serial, [byte[]]$Payload) {
  if ($Serial.Count -ne 8) { throw 'Serial must be exactly 8 bytes.' }
  [byte[]]$body = @(0x5A, 0x02) + $Serial + @(($Payload.Count -shr 8), ($Payload.Count -band 0xFF), 0x00, 0x01) + $Payload
  $crc = Crc16 $body
  return [byte[]](@(0x00) + $body + @(($crc -shr 8), ($crc -band 0xFF)))
}

function PacketList([byte[]]$First, [byte[]]$Second = $null) {
  $list = New-Object 'System.Collections.Generic.List[byte[]]'
  $list.Add($First)
  if ($null -ne $Second) { $list.Add($Second) }
  return ,$list
}

function Scan([int]$Seconds = 5) {
  $found = [hashtable]::Synchronized(@{})
  $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()
  $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active
  $sourceId = "YCOnionScan-$([Guid]::NewGuid())"
  Register-ObjectEvent $watcher Received -SourceIdentifier $sourceId -MessageData $found -Action {
    $event = $Event.SourceEventArgs
    $name = $event.Advertisement.LocalName
    $manufacturer = [byte[]]@()
    foreach ($section in $event.Advertisement.ManufacturerData) {
      $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($section.Data)
      [byte[]]$vendor = New-Object byte[] $reader.UnconsumedBufferLength
      $reader.ReadBytes($vendor)
      $manufacturer = @([byte]($section.CompanyId -band 0xFF), [byte]($section.CompanyId -shr 8)) + $vendor
      break
    }
    $services = @($event.Advertisement.ServiceUuids | ForEach-Object { $_.ToString().ToLowerInvariant() })
    $looksYC = $name -match '(?i)energy|pudding|^et_|yc|pizzc' -or ($manufacturer.Count -ge 2 -and $manufacturer[0] -eq 0x04 -and $manufacturer[1] -eq 0x05) -or $services -match '^0000(1828|ffe0)-'
    if ($looksYC) {
      $Event.MessageData[$event.BluetoothAddress.ToString('X12')] = [pscustomobject]@{ Name = $(if ($name) {$name} else {'YC Onion'}); Address = $event.BluetoothAddress; Rssi = $event.RawSignalStrengthInDBm; Manufacturer = $manufacturer; Services = $services }
    }
  }
  $watcher.Start()
  Start-Sleep -Seconds $Seconds
  $watcher.Stop()
  Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
  Get-Job | Where-Object { $_.Name -eq $sourceId } | Remove-Job -Force -ErrorAction SilentlyContinue
  return @($found.Values | Sort-Object Rssi -Descending)
}

function SerialFromManufacturer([byte[]]$Data) {
  if ($Data.Count -ge 4 -and $Data[0] -eq 0x04 -and $Data[1] -eq 0x05) { $start = 4 } elseif ($Data.Count -ge 3) { $start = 2 } else { return $null }
  [byte[]]$serial = New-Object byte[] 8
  $count = [Math]::Min(8, $Data.Count - $start)
  if ($count -gt 0) { [Array]::Copy($Data, $start, $serial, 0, $count) }
  return $serial
}

function FindDevice([string]$Target) {
  $devices = @(Scan)
  if (!$devices.Count) { throw 'No YC Onion Bluetooth device was found. Turn it on and close its phone app.' }
  if (!$Target) { return $devices[0] }
  $normalized = $Target -replace '[:-]', ''
  $match = $devices | Where-Object { $_.Address.ToString('X12') -eq $normalized -or $_.Name -like "*$Target*" } | Select-Object -First 1
  if (!$match) { throw "The selected device '$Target' was not found." }
  return $match
}

function WritePackets($Candidate, [string]$Service, [string]$Write, $Packets) {
  $device = Await ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($Candidate.Address)) ([Windows.Devices.Bluetooth.BluetoothLEDevice])
  if (!$device) { throw 'Windows could not open the Bluetooth device.' }
  try {
    $services = Await ($device.GetGattServicesForUuidAsync((FullUuid $Service), [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult])
    if ($services.Status.ToString() -ne 'Success' -or !$services.Services.Count) { throw "BLE service $Service is unavailable ($($services.Status))." }
    $chars = Await ($services.Services[0].GetCharacteristicsForUuidAsync((FullUuid $Write), [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult])
    if ($chars.Status.ToString() -ne 'Success' -or !$chars.Characteristics.Count) { throw "BLE write characteristic $Write is unavailable ($($chars.Status))." }
    $characteristic = $chars.Characteristics[0]
    foreach ($packet in $Packets) {
      $writer = [Windows.Storage.Streams.DataWriter]::new()
      $writer.WriteBytes($packet)
      $option = if (($characteristic.CharacteristicProperties -band [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Write) -ne 0) { [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption]::WriteWithResponse } else { [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption]::WriteWithoutResponse }
      $status = Await ($characteristic.WriteValueAsync($writer.DetachBuffer(), $option)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCommunicationStatus])
      $writer.Dispose()
      if ($status.ToString() -ne 'Success') { throw "Bluetooth write failed ($status)." }
      Start-Sleep -Milliseconds 60
    }
  } finally { $device.Dispose() }
}

try {
  $command = if ($Arguments.Count) { $Arguments[0].ToLowerInvariant() } else { 'help' }
  $positionals = New-Object System.Collections.Generic.List[string]
  $deviceTarget = ''; $serialText = ''; $service = ''; $write = ''
  for ($i = 1; $i -lt $Arguments.Count; $i++) {
    switch ($Arguments[$i]) {
      '--device' { $deviceTarget = $Arguments[++$i] }
      '--serial' { $serialText = $Arguments[++$i] }
      '--service' { $service = $Arguments[++$i] }
      '--write' { $write = $Arguments[++$i] }
      '--timeout' { $i++ }
      default { $positionals.Add($Arguments[$i]) }
    }
  }
  if ($command -eq 'devices') {
    foreach ($d in @(Scan)) {
      $serial = SerialFromManufacturer $d.Manufacturer
      Write-Output "$($d.Name)  id=$($d.Address.ToString('X12'))  rssi=$($d.Rssi)  serial=$(if ($serial) { Hex $serial } else { 'unknown' })  manufacturer=$(if ($d.Manufacturer.Count) { Hex $d.Manufacturer } else { 'none' })"
    }
    exit 0
  }
  $candidate = FindDevice $deviceTarget
  [byte[]]$serial = if ($serialText) { HexBytes $serialText } else { SerialFromManufacturer $candidate.Manufacturer }
  if ($command -eq 'raw') {
    if (!$service -or !$write -or !$positionals.Count) { throw 'raw requires packet, --service, and --write.' }
    $packets = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($packetText in $positionals) { $packets.Add((HexBytes $packetText)) }
    WritePackets $candidate $service $write $packets
    Write-Output "$($candidate.Name): wrote $($packets.Count) packet(s)"
    exit 0
  }
  if (!$serial) { throw 'The device serial was not advertised. Select the device again after scanning.' }
  $stateDir = Join-Path $env:LOCALAPPDATA 'YCOnion'; $stateFile = Join-Path $stateDir 'state.json'
  $state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ brightness = 100; isOn = $false } }
  $brightness = [int]$state.brightness
  $packets = $null
  switch ($command) {
    'on' { $brightness = [Math]::Max($brightness, 1); $packets = PacketList (Frame $serial @([byte]0x05, [byte]$brightness)); $state.isOn = $true }
    'off' { $brightness = 0; $packets = PacketList (Frame $serial @([byte]0x05, [byte]0)); $state.isOn = $false }
    'toggle' { $brightness = if ($state.isOn) { 0 } else { [Math]::Max([int]$state.brightness, 1) }; $packets = PacketList (Frame $serial @([byte]0x05, [byte]$brightness)); $state.isOn = !$state.isOn }
    'brightness' { $brightness = [int]$positionals[0]; $packets = PacketList (Frame $serial @([byte]0x05, [byte]$brightness)); $state.isOn = $brightness -gt 0 }
    'hsi' { $h=[int]$positionals[0]; $s=[int]$positionals[1]; $brightness=[int]$positionals[2]; $packets=PacketList (Frame $serial @([byte]0x00,[byte](($h-shr 8)-band 0xFF),[byte]($h-band 0xFF),[byte]$s)) (Frame $serial @([byte]0x05,[byte]$brightness)); $state.isOn=$brightness -gt 0 }
    'cct' { $k=[int]$positionals[0]; $brightness=[int]$positionals[1]; $packets=PacketList (Frame $serial @([byte]0x01,[byte](($k-shr 8)-band 0xFF),[byte]($k-band 0xFF),[byte]0)) (Frame $serial @([byte]0x05,[byte]$brightness)); $state.isOn=$brightness -gt 0 }
    'effect' { $families=@{cct=2;rgb=3;police=4}; $f=[byte]$families[$positionals[0]]; $id=[byte][int]$positionals[1]; $brightness=[int]$positionals[3]; $packets=PacketList (Frame $serial @($f,$id)) (Frame $serial @([byte]0x05,[byte]$brightness)); $state.isOn=$brightness -gt 0 }
    default { throw "Unknown command: $command" }
  }
  if ($brightness -gt 0) { $state.brightness = $brightness }
  $usesModernService = @($candidate.Services | Where-Object { $_ -eq (FullUuid '1828').ToString().ToLowerInvariant() }).Count -gt 0
  WritePackets $candidate $(if ($usesModernService) {'1828'} else {'FFE0'}) $(if ($usesModernService) {'2ADD'} else {'FFE1'}) $packets
  New-Item -ItemType Directory -Force $stateDir | Out-Null
  $state | ConvertTo-Json | Set-Content -Encoding UTF8 $stateFile
  Write-Output "$($candidate.Name): $command"
} catch {
  [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
  exit 1
}
