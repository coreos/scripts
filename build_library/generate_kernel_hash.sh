#!/usr/bin/python

import hashlib
import json
import os
import sys

path=sys.argv[1]
version=sys.argv[2]

with open(path, "rb") as f:
    kernel = f.read()
    print json.dumps({"9": {"binaryvalues": [{"prefix": "grub_linux", "values": [{"value": hashlib.sha1(kernel).hexdigest(), "description": "coreos-%s" % version}]}]}})
