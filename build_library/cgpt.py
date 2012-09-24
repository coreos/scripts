#!/usr/bin/python
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import copy
import json
import os
import sys

# First sector we can use.
START_SECTOR = 64

class ConfigNotFound(Exception):
  pass
class PartitionNotFound(Exception):
  pass
class InvalidLayout(Exception):
  pass


def LoadPartitionConfig(filename):
  """Loads a partition tables configuration file into a Python object.

  Args:
    filename: Filename to load into object
  Returns:
    Object containing disk layout configuration
  """

  if not os.path.exists(filename):
    raise ConfigNotFound("Partition config %s was not found!" % filename)
  with open(filename) as f:
    config = json.load(f)
    f.close()

  metadata = config["metadata"]
  metadata["block_size"] = int(metadata["block_size"])

  for layout_name, layout in config["layouts"].items():
    for part in layout:
      part["blocks"] = int(part["blocks"])
      part["bytes"] = part["blocks"] * metadata["block_size"]

      if "fs_blocks" in part:
        part["fs_blocks"] = int(part["fs_blocks"])
        part["fs_bytes"] = part["fs_blocks"] * metadata["fs_block_size"]

        if part["fs_bytes"] > part["bytes"]:
          raise InvalidLayout("Filesystem may not be larger than partition")

  return config


def GetTableTotals(config, partitions):
  """Calculates total sizes/counts for a partition table.

  Args:
    config: Partition configuration file object
    partitions: List of partitions to process
  Returns:
    Dict containing totals data
  """

  ret = {
    "expand_count": 0,
    "expand_min": 0,
    "block_count": START_SECTOR * config["metadata"]["block_size"]
  }

  # Total up the size of all non-expanding partitions to get the minimum
  # required disk size.
  for partition in partitions:
    if "features" in partition and "expand" in partition["features"]:
      ret["expand_count"] += 1
      ret["expand_min"] += partition["blocks"]
    else:
      ret["block_count"] += partition["blocks"]

  # At present, only one expanding partition is permitted.
  # Whilst it'd be possible to have two, we don't need this yet
  # and it complicates things, so it's been left out for now.
  if ret["expand_count"] > 1:
    raise InvalidLayout("1 expand partition allowed, %d requested"
                        % ret["expand_count"])

  ret["min_disk_size"] = ret["block_count"] + ret["expand_min"]

  return ret


def GetPartitionTable(config, image_type):
  """Generates requested image_type layout from a layout configuration.

  This loads the base table and then overlays the requested layout over
  the base layout.

  Args:
    config: Partition configuration file object
    image_type: Type of image eg base/test/dev/factory_install
  Returns:
    Object representing a selected partition table
  """

  partitions = config["layouts"]["base"]

  if image_type != "base":
    for partition_t in config["layouts"][image_type]:
      for partition in partitions:
        if partition["type"] == "blank" or partition_t["type"] == "blank":
          continue
        if partition_t["num"] == partition["num"]:
          for k, v in partition_t.items():
            partition[k] = v

  return partitions


def GetScriptShell():
  """Loads and returns the skeleton script for our output script.

  Returns:
    A string containg the skeleton script
  """

  script_shell_path = os.path.join(os.path.dirname(__file__), "cgpt_shell.sh")
  with open(script_shell_path, "r") as f:
    script_shell = "".join(f.readlines())
    f.close()

  # Before we return, insert the path to this tool so somebody reading the
  # script later can tell where it was generated.
  script_shell = script_shell.replace("@SCRIPT_GENERATOR@", script_shell_path)

  return script_shell


def WriteLayoutFunction(sfile, func_name, image_type, config):
  """Writes a shell script function to write out a given partition table.

  Args:
    sfile: File handle we're writing to
    func_name: Function name to write out for specified layout
    image_type: Type of image eg base/test/dev/factory_install
    config: Partition configuration file object
  """

  partitions = GetPartitionTable(config, image_type)
  partition_totals = GetTableTotals(config, partitions)

  sfile.write("%s() {\ncreate_image $1 %d %s\n" % (
  func_name, partition_totals["min_disk_size"],
  config["metadata"]["block_size"]))

  sfile.write("CURR=%d\n" % START_SECTOR)
  sfile.write("$GPT create $1\n")

  # Pass 1: Set up the expanding partition size.
  for partition in partitions:
    partition["var"] = partition["blocks"]
    if partition["type"] != "blank":

      if partition["num"] == 1:
        if "features" in partition and "expand" in partition["features"]:
          sfile.write("if [ -b $1 ]; then\n")
          sfile.write("STATEFUL_SIZE=$(( $(numsectors $1) - %d))\n" %
            partition_totals["block_count"])
          sfile.write("else\n")
          sfile.write("STATEFUL_SIZE=%s\n" % partition["blocks"])
          sfile.write("fi\n")
          partition["var"] = "$STATEFUL_SIZE"

  # Pass 2: Write out all the cgpt add commands.
  for partition in partitions:
    if partition["type"] != "blank":
      sfile.write("$GPT add -i %d -b $CURR -s %s -t %s -l %s $1 && " % (
        partition["num"], str(partition["var"]), partition["type"],
        partition["label"]))

    # Increment the CURR counter ready for the next partition.
    sfile.write("CURR=$(( $CURR + %s ))\n" % partition["var"])

  # Set default priorities on kernel partitions
  sfile.write("$GPT add -i 2 -S 0 -T 15 -P 15 $1\n")
  sfile.write("$GPT add -i 4 -S 0 -T 15 -P 0 $1\n")
  sfile.write("$GPT add -i 6 -S 0 -T 15 -P 0 $1\n")

  sfile.write("$GPT boot -p -b $2 -i 12 $1\n")
  sfile.write("$GPT show $1\n")
  sfile.write("}\n")


def GetPartitionByNumber(partitions, num):
  """Given a partition table and number returns the partition object.

  Args:
    partitions: List of partitions to search in
    num: Number of partition to find
  Returns:
    An object for the selected partition
  """
  for partition in partitions:
    if partition["type"] == "blank":
      continue
    if partition["num"] == int(num):
      return partition

  raise PartitionNotFound("Partition not found")


def WritePartitionScript(image_type, layout_filename, sfilename):
  """Writes a shell script with functions for the base and requested layouts.

  Args:
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    sfilename: Filename to write the finished script to
  """

  config = LoadPartitionConfig(layout_filename)

  sfile = open(sfilename, "w")
  script_shell = GetScriptShell()
  sfile.write(script_shell)

  WriteLayoutFunction(sfile, "write_base_table", "base", config)
  WriteLayoutFunction(sfile, "write_partition_table", image_type, config)

  sfile.close()


def GetBlockSize(layout_filename):
  """Returns the partition table block size.

  Args:
    layout_filename: Path to partition configuration file
  Returns:
    Block size of all partitions in the layout
  """

  config = LoadPartitionConfig(layout_filename)
  return config["metadata"]["block_size"]


def GetFilesystemBlockSize(layout_filename):
  """Returns the filesystem block size.

  This is used for all partitions in the table that have filesystems.

  Args:
    layout_filename: Path to partition configuration file
  Returns:
    Block size of all filesystems in the layout
  """

  config = LoadPartitionConfig(layout_filename)
  return config["metadata"]["fs_block_size"]


def GetPartitionSize(image_type, layout_filename, num):
  """Returns the partition size of a given partition for a given layout type.

  Args:
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Size of selected partition in bytes
  """

  config = LoadPartitionConfig(layout_filename)
  partitions = GetPartitionTable(config, image_type)
  partition = GetPartitionByNumber(partitions, num)

  return partition["bytes"]


def GetFilesystemSize(image_type, layout_filename, num):
  """Returns the filesystem size of a given partition for a given layout type.

  If no filesystem size is specified, returns the partition size.

  Args:
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Size of selected partition filesystem in bytes
  """

  config = LoadPartitionConfig(layout_filename)
  partitions = GetPartitionTable(config, image_type)
  partition = GetPartitionByNumber(partitions, num)

  if "fs_bytes" in partition:
    return partition["fs_bytes"]
  else:
    return partition["bytes"]


def GetLabel(image_type, layout_filename, num):
  """Returns the label for a given partition.

  Args:
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Label of selected partition, or "UNTITLED" if none specified
  """

  config = LoadPartitionConfig(layout_filename)
  partitions = GetPartitionTable(config, image_type)
  partition = GetPartitionByNumber(partitions, num)

  if "label" in partition:
    return partition["label"]
  else:
    return "UNTITLED"


def DoDebugOutput(image_type, layout_filename):
  """Prints out a human readable disk layout in on-disk order.

  This will round values larger than 1MB, it's exists to quickly
  visually verify a layout looks correct.

  Args:
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
  """
  config = LoadPartitionConfig(layout_filename)
  partitions = GetPartitionTable(config, image_type)

  for partition in partitions:
    if partition["bytes"] < 1024 * 1024:
      size = "%d bytes" % partition["bytes"]
    else:
      size = "%d MB" % (partition["bytes"] / 1024 / 1024)
    if "label" in partition:
      if "fs_bytes" in partition:
        if partition["fs_bytes"] < 1024 * 1024:
          fs_size = "%d bytes" % partition["fs_bytes"]
        else:
          fs_size = "%d MB" % (partition["fs_bytes"] / 1024 / 1024)
        print "%s - %s/%s" % (partition["label"], fs_size, size)
      else:
        print "%s - %s" % (partition["label"], size)
    else:
      print "blank - %s" %  size


def main(argv):
  action_map = {
    "write": {
      "argc": 4,
      "usage": "<image_type> <partition_config_file> <script_file>",
      "func": WritePartitionScript
    },
    "readblocksize": {
      "argc": 2,
      "usage": "<partition_config_file>",
      "func": GetBlockSize
    },
    "readfsblocksize": {
      "argc": 2,
      "usage": "<partition_config_file>",
      "func": GetFilesystemBlockSize
    },
    "readpartsize": {
      "argc": 4,
      "usage": "<image_type> <partition_config_file> <partition_num>",
      "func": GetPartitionSize
    },
    "readfssize": {
      "argc": 4,
      "usage": "<image_type> <partition_config_file> <partition_num>",
      "func": GetFilesystemSize
    },
    "readlabel": {
      "argc": 4,
      "usage": "<image_type> <partition_config_file> <partition_num>",
      "func": GetLabel
    },
    "debug": {
      "argc": 3,
      "usage": "<image_type> <partition_config_file>",
      "func": DoDebugOutput
    }
  }

  if len(sys.argv) < 2 or sys.argv[1] not in action_map:
    print "Usage: %s <action>\n" % sys.argv[0]
    print "Valid actions are:"
    for action in action_map:
      print "  %s %s" % (action, action_map[action]["usage"])
    sys.exit(1)
  else:
    action_name = sys.argv[1]
    action = action_map[action_name]
    if action["argc"] == len(sys.argv) - 1:
      print action["func"](*sys.argv[2:])
    else:
      sys.exit("Usage: %s %s %s" % (sys.argv[0], sys.argv[1], action["usage"]))

if __name__ == "__main__":
  main(sys.argv)
