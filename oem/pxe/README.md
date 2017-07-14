#PXE OEM utils

##About

These scripts are used to manage downloading CoreOS images to use
on a PXE server. All scripts here should be considered in the public domain.

Outside of this directory is a "generic" scripts directory.  This is the
location of any scripts not specific to any OEM.  There you will find useful
scripts like `check_etag.sh`.

The `pxe_image.sh` script combines some elements from `check_etag.sh` with
the ideas behind `glance_load.sh`, essentially watching for a change in
the etag of a file, and pulling a new CoreOS image when the etag changes.

##Example Usage

While this is meant to run as a cron job, it can be run as a one of script as well.

```
$ release=beta arch=arm64-usr ./pxe_image.sh
```
