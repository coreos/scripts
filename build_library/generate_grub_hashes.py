#!/usr/bin/python

import hashlib
import json
import os
import string
import subprocess
import sys

filename = sys.argv[1] 
grubdir = sys.argv[2]
outputdir = sys.argv[3]
version = sys.argv[4]
bootoffset = string.atoi(subprocess.check_output(['cgpt', 'show', '-i', '2', '-b', filename])) * 512
with open(filename, "rb") as f:
    boot = f.read(440)
    f.seek(bootoffset)
    diskboot = f.read(512)
    corelen = bytearray(diskboot)[508] | bytearray(diskboot)[509] << 8
    f.seek(bootoffset+512)
    core = f.read(corelen * 512)
    hashes = {"4": {"binaryvalues": [{"values": [{"value": hashlib.sha1(boot).hexdigest(), "description": "CoreOS Grub boot.img %s" % version}]}]},
              "8": {"binaryvalues" : [{"values": [{"value": hashlib.sha1(diskboot).hexdigest(), "description": "CoreOS Grub diskboot.img %s" % version}]}]},
              "9": {"binaryvalues": [{"values": [{"value": hashlib.sha1(core).hexdigest(), "description": "CoreOS Grub core.img %s" % version}]}]}}
    with open(os.path.join(outputdir, "grub_loader.config"), "w") as f:
        f.write(json.dumps(hashes, sort_keys=True))


hashvalues = []
for folder, subs, files in os.walk(grubdir):
    for filename in files:
        if filename.endswith(".mod"):
            with open(os.path.join(folder, filename), "rb") as f:
                mod = f.read()
                value = hashlib.sha1(mod).hexdigest()
                description = "CoreOS Grub %s %s" % (filename, version)
                hashvalues.append({"value": value, "description": description})

with open(os.path.join(outputdir, "grub_modules.config"), "w") as f:
    f.write(json.dumps({"9": {"binaryvalues": [{"prefix": "grub_module", "values": hashvalues}]}}))

with open(os.path.join(outputdir, "kernel_cmdline.config"), "w") as f:
    f.write(json.dumps({"8": {"asciivalues": [{"prefix": "grub_kernel_cmdline", "values": [{"value": "rootflags=rw mount.usrflags=ro BOOT_IMAGE=/coreos/vmlinuz-[ab] mount.usr=/dev/mapper/usr verity.usr=PARTUUID=\S{36} rootflags=rw mount.usrflags=ro consoleblank=0 root=LABEL=ROOT (console=\S+)? (coreos.autologin=\S+)? verity.usrhash=\\S{64}", "description": "CoreOS kernel command line %s" % version}]}]}}))

commands = [{"value": '\[.*\]', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'gptprio.next -d usr -u usr_uuid', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'insmod all_video', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'linux /coreos/vmlinuz-[ab] rootflags=rw mount.usrflags=ro consoleblank=0 root=LABEL=ROOT (console=\S+)? (coreos.autologin=\S+)?', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'menuentry CoreOS \S+ --id=coreos\S* {', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'search --no-floppy --set first_boot --disk-uuid 00000000-0000-0000-0000-000000000001', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'search --no-floppy --set oem --part-label OEM --hint hd0,gpt1', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'set .+', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'setparams CoreOS default', "description": "CoreOS Grub configuration %s" % version},
            {"value": 'source (hd0,gpt6)/grub.cfg', "description": "CoreOS Grub configuration %s" % version}]

with open(os.path.join(outputdir, "grub_commands.config"), "w") as f:
    f.write(json.dumps({"8": {"asciivalues": [{"prefix": "grub_cmd", "values": commands}]}}))
