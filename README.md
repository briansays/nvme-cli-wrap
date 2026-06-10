# NVMe CLI Unlock Wrapper 

This script is intended to be part of a `buildroot` or similar style deployment of a pre-boot authentication software package that is installed in the sMBR on an TCG Opal 2.0 NVMe SSD for unlocking the drive at boot time. The script can also be run on a booted system to unlock drives that are not using Opal 2.0 sMBR as part of their SED configuration. 

## Known Issues: 

1. Error handling is garbage, packages and plugins may be missing but will be detected as present.
2. Probably 100 other things... this was built as a proof of concept.

_Made with Claude_
