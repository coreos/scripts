#OpenStack OEM utils

##About

These scripts are used to manage loading CoreOS images into an OpenStack
deployment.  All scripts here should be considered in the public domain.

Outside of this directory is a "generic" scripts directory.  This is the
location of any scripts not specific to any OEM.  There you will find useful
scripts like `check_etag.sh`.

To load images in an automated fashion via `python-glanceclient`, one may
use a cron job which will check the ETag on the remote file on the CoreOS
image storage then proceed with executing this script.


##Example Usage

First, load your openstack credentials using one of the following methods:

```
$ source ~/.openstack/keystonerc_${USERNAME}
```

```
$ export OS_PASSWORD=secure_password
$ export OS_AUTH_URL=http://my.keystone.auth-url.example.com:35357/v2.0/
$ export OS_USERNAME=redbeard
$ export OS_TENANT_NAME=coreos
```

Next, run the actual synchronization script:

```
$ ../generic/check_etag.sh && echo "Everything synced" || ./glance_load.sh
```

