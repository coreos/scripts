#!/usr/bin/python
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import copy
import json
import os
import re
import sys
import uuid
from optparse import OptionParser

# First sector we can use.
START_SECTOR = 64

class ConfigNotFound(Exception):
  pass
class PartitionNotFound(Exception):
  pass
class InvalidLayout(Exception):
  pass
class InvalidAdjustment(Exception):
  pass


def LoadPartitionConfig(filename):
  """Loads a partition tables configuration file into a Python object.

  Args:
    filename: Filename to load into object
  Returns:
    Object containing disk layout configuration
  """

  valid_keys = set(('_comment', 'metadata', 'layouts'))
  valid_layout_keys = set((
      '_comment', 'type', 'num', 'label', 'blocks', 'block_size', 'fs_blocks',
      'fs_block_size', 'features', 'uuid'))

  if not os.path.exists(filename):
    raise ConfigNotFound('Partition config %s was not found!' % filename)
  with open(filename) as f:
    config = json.load(f)

  try:
    metadata = config['metadata']
    for key in ('block_size', 'fs_block_size'):
      metadata[key] = int(metadata[key])

    unknown_keys = set(config.keys()) - valid_keys
    if unknown_keys:
      raise InvalidLayout('Unknown items: %r' % unknown_keys)

    if len(config['layouts']) <= 0:
      raise InvalidLayout('Missing "layouts" entries')

    for layout_name, layout in config['layouts'].items():
      for part in layout:
        unknown_keys = set(part.keys()) - valid_layout_keys
        if unknown_keys:
          raise InvalidLayout('Unknown items in layout %s: %r' %
                              (layout_name, unknown_keys))

        if part['type'] != 'blank':
          for s in ('num', 'label'):
            if not s in part:
              raise InvalidLayout('Layout "%s" missing "%s"' % (layout_name, s))

        part['blocks'] = int(part['blocks'])
        part['bytes'] = part['blocks'] * metadata['block_size']

        if 'fs_blocks' in part:
          part['fs_blocks'] = int(part['fs_blocks'])
          part['fs_bytes'] = part['fs_blocks'] * metadata['fs_block_size']

          if part['fs_bytes'] > part['bytes']:
            raise InvalidLayout(
                'Filesystem may not be larger than partition: %s %s: %d > %d' %
                (layout_name, part['label'], part['fs_bytes'], part['bytes']))

        if 'uuid' in part:
          try:
            # double check the string formatting
            part['uuid'] = str(uuid.UUID(part['uuid']))
          except ValueError as e:
            raise InvalidLayout('Invalid uuid %r: %s' % (part['uuid'], e))
        else:
          part['uuid'] = str(uuid.uuid4())
  except KeyError as e:
    raise InvalidLayout('Layout is missing required entries: %s' % e)

  return config




def GetPartitionTable(options, config, image_type):
  """Generates requested image_type layout from a layout configuration.
  This loads the base table and then overlays the requested layout over
  the base layout.

  Args:
    options: Flags passed to the script
    config: Partition configuration file object
    image_type: Type of image eg base/test/dev/factory_install
  Returns:
    Object representing a selected partition table
  """

  partitions = config['layouts']['base']
  metadata = config['metadata']

  if image_type != 'base':
    for partition_t in config['layouts'][image_type]:
      for partition in partitions:
        if partition['type'] == 'blank' or partition_t['type'] == 'blank':
          continue
        if partition_t['num'] == partition['num']:
          for k, v in partition_t.items():
            partition[k] = v

  for adjustment_str in options.adjust_part.split():
    adjustment = adjustment_str.split(':')
    if len(adjustment) < 2:
      raise InvalidAdjustment('Adjustment specified was incomplete')

    label = adjustment[0]
    operator = adjustment[1][0]
    operand = adjustment[1][1:]
    ApplyPartitionAdjustment(partitions, metadata, label, operator, operand)

  return partitions


def ApplyPartitionAdjustment(partitions, metadata, label, operator, operand):
  """Applies an adjustment to a partition specified by label

  Args:
    partitions: Partition table to modify
    metadata: Partition table metadata
    label: The label of the partition to adjust
    operator: Type of adjustment (+/-/=)
    operand: How much to adjust by
  """

  partition = GetPartitionByLabel(partitions, label)

  operand_digits = re.sub('\D', '', operand)
  size_factor = block_factor = 1
  suffix = operand[len(operand_digits):]
  if suffix:
    size_factors = { 'B': 0, 'K': 1, 'M': 2, 'G': 3, 'T': 4, }
    try:
      size_factor = size_factors[suffix[0].upper()]
    except KeyError:
      raise InvalidAdjustment('Unknown size type %s' % suffix)
    if size_factor == 0 and len(suffix) > 1:
      raise InvalidAdjustment('Unknown size type %s' % suffix)
    block_factors = { '': 1024, 'B': 1000, 'IB': 1024, }
    try:
      block_factor = block_factors[suffix[1:].upper()]
    except KeyError:
      raise InvalidAdjustment('Unknown size type %s' % suffix)

  operand_bytes = int(operand_digits) * pow(block_factor, size_factor)

  if operand_bytes % metadata['block_size'] == 0:
    operand_blocks = operand_bytes / metadata['block_size']
  else:
    raise InvalidAdjustment('Adjustment size not divisible by block size')

  if operator == '+':
    partition['blocks'] += operand_blocks
    partition['bytes'] += operand_bytes
  elif operator == '-':
    partition['blocks'] -= operand_blocks
    partition['bytes'] -= operand_bytes
  elif operator == '=':
    partition['blocks'] = operand_blocks
    partition['bytes'] = operand_bytes
  else:
    raise ValueError('unknown operator %s' % operator)

  if partition['type'] == 'rootfs':
    # If we're adjusting a rootFS partition, we assume the full partition size
    # specified is being used for the filesytem, minus the space reserved for
    # the hashpad.
    partition['fs_bytes'] = partition['bytes']
    partition['fs_blocks'] = partition['fs_bytes'] / metadata['fs_block_size']
    partition['blocks'] = int(partition['blocks'] * 1.15)
    partition['bytes'] = partition['blocks'] * metadata['block_size']


def GetPartitionTableFromConfig(options, layout_filename, image_type):
  """Loads a partition table and returns a given partition table type

  Args:
    options: Flags passed to the script
    layout_filename: The filename to load tables from
    image_type: The type of partition table to return
  """

  config = LoadPartitionConfig(layout_filename)
  partitions = GetPartitionTable(options, config, image_type)

  return partitions

def GetScriptShell():
  """Loads and returns the skeleton script for our output script.

  Returns:
    A string containg the skeleton script
  """

  script_shell_path = os.path.join(os.path.dirname(__file__), 'cgpt_shell.sh')
  with open(script_shell_path, 'r') as f:
    script_shell = ''.join(f.readlines())

  # Before we return, insert the path to this tool so somebody reading the
  # script later can tell where it was generated.
  script_shell = script_shell.replace('@SCRIPT_GENERATOR@', script_shell_path)

  return script_shell


def WriteLayoutFunction(options, sfile, func_name, image_type, config):
  """Writes a shell script function to write out a given partition table.

  Args:
    options: Flags passed to the script
    sfile: File handle we're writing to
    func_name: Function name to write out for specified layout
    image_type: Type of image eg base/test/dev/factory_install
    config: Partition configuration file object
  """

  partitions = GetPartitionTable(options, config, image_type)
  disk_block_count = START_SECTOR * config['metadata']['block_size']

  for partition in partitions:
    disk_block_count += partition['blocks']

  sfile.write('%s() {\ncreate_image $1 %d %s\n' % (
      func_name, disk_block_count,
      config['metadata']['block_size']))

  sfile.write('CURR=%d\n' % START_SECTOR)
  sfile.write('$GPT create $1\n')

  for partition in partitions:
    if partition['type'] != 'blank':
      sfile.write('$GPT add -i %d -b $CURR -s %s -t %s -l %s -u %s $1 && ' % (
          partition['num'], str(partition['blocks']), partition['type'],
          partition['label'], partition['uuid']))
    if partition['type'] == 'efi':
      sfile.write('$GPT boot -p -b $2 -i %d $1\n' % partition['num'])

    # Increment the CURR counter ready for the next partition.
    sfile.write('CURR=$(( $CURR + %s ))\n' % partition['blocks'])

  sfile.write('$GPT show $1\n')
  sfile.write('}\n')


def GetPartitionByNumber(partitions, num):
  """Given a partition table and number returns the partition object.

  Args:
    partitions: List of partitions to search in
    num: Number of partition to find
  Returns:
    An object for the selected partition
  """
  for partition in partitions:
    if partition['type'] == 'blank':
      continue
    if partition['num'] == int(num):
      return partition

  raise PartitionNotFound('Partition not found')


def GetPartitionByLabel(partitions, label):
  """Given a partition table and label returns the partition object.

  Args:
    partitions: List of partitions to search in
    label: Label of partition to find
  Returns:
    An object for the selected partition
  """
  for partition in partitions:
    if 'label' not in partition:
      continue
    if partition['label'] == label:
      return partition

  raise PartitionNotFound('Partition not found')


def WritePartitionScript(options, image_type, layout_filename, sfilename):
  """Writes a shell script with functions for the base and requested layouts.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    sfilename: Filename to write the finished script to
  """

  config = LoadPartitionConfig(layout_filename)

  with open(sfilename, 'w') as f:
    script_shell = GetScriptShell()
    f.write(script_shell)

    WriteLayoutFunction(options, f, 'write_base_table', 'base', config)
    WriteLayoutFunction(options, f, 'write_partition_table', image_type, config)


def GetBlockSize(options, layout_filename):
  """Returns the partition table block size.

  Args:
    options: Flags passed to the script
    layout_filename: Path to partition configuration file
  Returns:
    Block size of all partitions in the layout
  """

  config = LoadPartitionConfig(layout_filename)
  return config['metadata']['block_size']


def GetFilesystemBlockSize(options, layout_filename):
  """Returns the filesystem block size.

  Args:
    options: Flags passed to the script

  This is used for all partitions in the table that have filesystems.

  Args:
    layout_filename: Path to partition configuration file
  Returns:
    Block size of all filesystems in the layout
  """

  config = LoadPartitionConfig(layout_filename)
  return config['metadata']['fs_block_size']


def GetPartitionSize(options, image_type, layout_filename, num):
  """Returns the partition size of a given partition for a given layout type.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Size of selected partition in bytes
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  return partition['bytes']


def GetFilesystemSize(options, image_type, layout_filename, num):
  """Returns the filesystem size of a given partition for a given layout type.

  If no filesystem size is specified, returns the partition size.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Size of selected partition filesystem in bytes
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  if 'fs_bytes' in partition:
    return partition['fs_bytes']
  else:
    return partition['bytes']


def GetLabel(options, image_type, layout_filename, num):
  """Returns the label for a given partition.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Label of selected partition, or 'UNTITLED' if none specified
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  if 'label' in partition:
    return partition['label']
  else:
    return 'UNTITLED'


def GetNum(options, image_type, layout_filename, label):
  """Returns the number for a given label.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    label: Label of the partition you want to read from
  Returns:
    Number of selected partition, or '-1' if there is no number
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByLabel(partitions, label)

  if 'num' in partition:
    return partition['num']
  else:
    return '-1'


def GetUuid(options, image_type, layout_filename, label):
  """Returns the unique partition UUID for a given label.

  Note: Only useful if the UUID is specified in the config file, otherwise
  the value returned unlikely to be what is actually used in the image.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/prod
    layout_filename: Path to partition configuration file
    label: Label of the partition you want to read from
  Returns:
    String containing the requested UUID
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByLabel(partitions, label)
  return partition['uuid']


def DoDebugOutput(options, image_type, layout_filename):
  """Prints out a human readable disk layout in on-disk order.

  This will round values larger than 1MB, it's exists to quickly
  visually verify a layout looks correct.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
  """
  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)

  for partition in partitions:
    if partition['bytes'] < 1024 * 1024:
      size = '%d bytes' % partition['bytes']
    else:
      size = '%d MB' % (partition['bytes'] / 1024 / 1024)
    if 'label' in partition:
      if 'fs_bytes' in partition:
        if partition['fs_bytes'] < 1024 * 1024:
          fs_size = '%d bytes' % partition['fs_bytes']
        else:
          fs_size = '%d MB' % (partition['fs_bytes'] / 1024 / 1024)
        print '%s - %s/%s' % (partition['label'], fs_size, size)
      else:
        print '%s - %s' % (partition['label'], size)
    else:
      print 'blank - %s' %  size


def DoParseOnly(options, image_type, layout_filename):
  """Parses a layout file only, used before reading sizes to check for errors.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
  """
  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)


def main(argv):
  action_map = {
    'write': {
      'usage': ['<image_type>', '<partition_config_file>', '<script_file>'],
      'func': WritePartitionScript,
    },
    'readblocksize': {
      'usage': ['<partition_config_file>'],
      'func': GetBlockSize,
    },
    'readfsblocksize': {
      'usage': ['<partition_config_file>'],
      'func': GetFilesystemBlockSize,
    },
    'readpartsize': {
      'usage': ['<image_type>', '<partition_config_file>', '<partition_num>'],
      'func': GetPartitionSize,
    },
    'readfssize': {
      'usage': ['<image_type>', '<partition_config_file>', '<partition_num>'],
      'func': GetFilesystemSize,
    },
    'readlabel': {
      'usage': ['<image_type>', '<partition_config_file>', '<partition_num>'],
      'func': GetLabel,
    },
    'readnum': {
      'usage': ['<image_type>', '<partition_config_file>', '<label>'],
      'func': GetNum,
    },
    'readuuid': {
      'usage': ['<image_type>', '<partition_config_file>', '<label>'],
      'func': GetUuid,
    },
    'debug': {
      'usage': ['<image_type>', '<partition_config_file>'],
      'func': DoDebugOutput,
    },
    'parseonly': {
      'usage': ['<image_type>', '<partition_config_file>'],
      'func': DoParseOnly,
    }
  }

  parser = OptionParser()
  parser.add_option("--adjust_part", dest="adjust_part",
                    help="adjust partition sizes", default="")
  (options, args) = parser.parse_args()

  if len(args) < 1 or args[0] not in action_map:
    print 'Usage: %s <action>\n' % sys.argv[0]
    print 'Valid actions are:'
    for action in action_map:
      print '  %s %s' % (action, ' '.join(action_map[action]['usage']))
    sys.exit(1)
  else:
    action_name = args[0]
    action = action_map[action_name]
    if len(action['usage']) == len(args) - 1:
      print action['func'](options, *args[1:])
    else:
      sys.exit('Usage: %s %s %s' % (sys.argv[0], args[0],
               ' '.join(action['usage'])))


if __name__ == '__main__':
  main(sys.argv)
