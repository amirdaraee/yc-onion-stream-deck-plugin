# Privacy policy

YC Onion Control operates locally on the user's computer.

The plugin:

- scans for nearby Bluetooth Low Energy devices only when discovery or a
  configured action requires it;
- stores the selected device identifier, advertised device serial, last known
  brightness, and local toggle state on the user's computer;
- does not create an account;
- does not include analytics or advertising;
- does not transmit personal information or device information to the project
  maintainer or any third party.

On macOS, controller state is stored under
`~/Library/Application Support/YCOnion/`. On Windows, state is stored under
`%LOCALAPPDATA%\YCOnion\`. Removing those folders deletes the controller's saved
state.

Stream Deck and the operating system may maintain their own application logs
and Bluetooth records under their respective privacy policies.

Questions about this policy can be submitted through the repository's issue
tracker without including Bluetooth identifiers or other personal information.

Last updated: August 19, 2026.
