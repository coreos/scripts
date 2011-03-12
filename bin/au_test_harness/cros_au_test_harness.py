#!/usr/bin/python

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""This module runs a suite of Auto Update tests.

  The tests can be run on either a virtual machine or actual device depending
  on parameters given.  Specific tests can be run by invoking --test_prefix.
  Verbose is useful for many of the tests if you want to see individual commands
  being run during the update process.
"""

import optparse
import os
import re
import sys
import tempfile
import unittest

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
import cros_build_lib as cros_lib

import au_test
import au_worker
import dummy_au_worker
import dev_server_wrapper
import parallel_test_job
import update_exception


def _PrepareTestSuite(options, use_dummy_worker=False):
  """Returns a prepared test suite given by the options and test class."""
  au_test.AUTest.ProcessOptions(options, use_dummy_worker)
  test_loader = unittest.TestLoader()
  test_loader.testMethodPrefix = options.test_prefix
  return test_loader.loadTestsFromTestCase(au_test.AUTest)


def _PregenerateUpdates(options):
  """Determines all deltas that will be generated and generates them.

  This method effectively pre-generates the dev server cache for all tests.

  Args:
    options: options from parsed parser.
  Returns:
    Dictionary of Update Identifiers->Relative cache locations.
  Raises:
    update_exception.UpdateException if we fail to generate an update.
  """
  def _GenerateVMUpdate(target, src, private_key_path):
    """Generates an update using the devserver."""
    command = ['./enter_chroot.sh',
               '--nogit_config',
               '--',
               'sudo',
               'start_devserver',
               '--pregenerate_update',
               '--exit',
              ]
    # Add actual args to command.
    command.append('--image=%s' % cros_lib.ReinterpretPathForChroot(target))
    if src: command.append('--src_image=%s' %
                           cros_lib.ReinterpretPathForChroot(src))
    if options.type == 'vm': command.append('--for_vm')
    if private_key_path:
      command.append('--private_key=%s' %
                     cros_lib.ReinterpretPathForChroot(private_key_path))

    return cros_lib.RunCommandCaptureOutput(command, combine_stdout_stderr=True,
                                            print_cmd=True)

  # Use dummy class to mock out updates that would be run as part of a test.
  test_suite = _PrepareTestSuite(options, use_dummy_worker=True)
  test_result = unittest.TextTestRunner(verbosity=0).run(test_suite)
  if not test_result.wasSuccessful():
    raise update_exception.UpdateException(1,
                                           'Error finding updates to generate.')

  cros_lib.Info('The following delta updates are required.')
  update_ids = []
  jobs = []
  args = []
  for target, srcs in dummy_au_worker.DummyAUWorker.delta_list.items():
    for src_key in srcs:
      (src, _ , key) = src_key.partition('+')
      # TODO(sosa): Add private key as part of caching name once devserver can
      # handle it its own cache.
      update_id = dev_server_wrapper.GenerateUpdateId(target, src, key)
      print >> sys.stderr, 'AU: %s' % update_id
      update_ids.append(update_id)
      jobs.append(_GenerateVMUpdate)
      args.append((target, src, key))

  raw_results = parallel_test_job.RunParallelJobs(options.jobs, jobs, args,
                                                  print_status=True)
  results = []

  # Looking for this line in the output.
  key_line_re = re.compile('^PREGENERATED_UPDATE=([\w/.]+)')
  for result in raw_results:
    (return_code, output, _) = result
    if return_code != 0:
      cros_lib.Warning(output)
      raise update_exception.UpdateException(return_code,
                                             'Failed to generate all updates.')
    else:
      for line in output.splitlines():
        match = key_line_re.search(line)
        if match:
          # Convert blah/blah/update.gz -> update/blah/blah.
          path_to_update_gz = match.group(1).rstrip()
          (path_to_update_dir, _, _) = path_to_update_gz.rpartition(
              '/update.gz')
          results.append('/'.join(['update', path_to_update_dir]))
          break

  # Make sure all generation of updates returned cached locations.
  if len(raw_results) != len(results):
    raise update_exception.UpdateException(
        1, 'Insufficient number cache directories returned.')

  # Build the dictionary from our id's and returned cache paths.
  cache_dictionary = {}
  for index, id in enumerate(update_ids):
    cache_dictionary[id] = results[index]

  return cache_dictionary


def _RunTestsInParallel(options):
  """Runs the tests given by the options in parallel."""
  threads = []
  args = []
  test_suite = _PrepareTestSuite(options)
  for test in test_suite:
    test_name = test.id()
    test_case = unittest.TestLoader().loadTestsFromName(test_name)
    threads.append(unittest.TextTestRunner().run)
    args.append(test_case)

  results = parallel_test_job.RunParallelJobs(options.jobs, threads, args,
                                              print_status=False)
  for test_result in results:
    if not test_result.wasSuccessful():
      cros_lib.Die('Test harness was not successful')


def _InsertPublicKeyIntoImage(image_path, key_path):
  """Inserts public key into image @ static update_engine location."""
  from_dir = os.path.dirname(image_path)
  image = os.path.basename(image_path)
  crosutils_dir = os.path.abspath(__file__).rsplit('/', 2)[0]
  target_key_path = 'usr/share/update_engine/update-payload-key.pub.pem'

  # Temporary directories for this function.
  rootfs_dir = tempfile.mkdtemp(suffix='rootfs', prefix='tmp')
  stateful_dir = tempfile.mkdtemp(suffix='stateful', prefix='tmp')

  cros_lib.Info('Copying %s into %s' % (key_path, image_path))
  try:
    cros_lib.RunCommand(['./mount_gpt_image.sh',
                         '--from=%s' % from_dir,
                         '--image=%s' % image,
                         '--rootfs_mountpt=%s' % rootfs_dir,
                         '--stateful_mountpt=%s' % stateful_dir,
                        ], print_cmd=False, redirect_stdout=True,
                        redirect_stderr=True, cwd=crosutils_dir)
    path = os.path.join(rootfs_dir, target_key_path)
    dir_path = os.path.dirname(path)
    cros_lib.RunCommand(['sudo', 'mkdir', '--parents', dir_path],
                        print_cmd=False)
    cros_lib.RunCommand(['sudo', 'cp', '--force', '-p', key_path, path],
                        print_cmd=False)
  finally:
    # Unmount best effort regardless.
    cros_lib.RunCommand(['./mount_gpt_image.sh',
                         '--unmount',
                         '--rootfs_mountpt=%s' % rootfs_dir,
                         '--stateful_mountpt=%s' % stateful_dir,
                        ], print_cmd=False, redirect_stdout=True,
                        redirect_stderr=True, cwd=crosutils_dir)
    # Clean up our directories.
    os.rmdir(rootfs_dir)
    os.rmdir(stateful_dir)

  cros_lib.RunCommand(['bin/cros_make_image_bootable',
                       cros_lib.ReinterpretPathForChroot(from_dir),
                       image],
                      print_cmd=False, redirect_stdout=True,
                      redirect_stderr=True, enter_chroot=True,
                      cwd=crosutils_dir)


def _CleanPreviousWork(options):
  """Cleans up previous work from the devserver cache and local image cache."""
  cros_lib.Info('Cleaning up previous work.')
  # Wipe devserver cache.
  cros_lib.RunCommandCaptureOutput(
      ['sudo', 'start_devserver', '--clear_cache', '--exit', ],
      enter_chroot=True, print_cmd=False, combine_stdout_stderr=True)

  # Clean previous vm images if they exist.
  if options.type == 'vm':
    target_vm_image_path = '%s/chromiumos_qemu_image.bin' % os.path.dirname(
        options.target_image)
    base_vm_image_path = '%s/chromiumos_qemu_image.bin' % os.path.dirname(
        options.base_image)
    if os.path.exists(target_vm_image_path): os.remove(target_vm_image_path)
    if os.path.exists(base_vm_image_path): os.remove(base_vm_image_path)


def main():
  parser = optparse.OptionParser()
  parser.add_option('-b', '--base_image',
                    help='path to the base image.')
  parser.add_option('-r', '--board',
                    help='board for the images.')
  parser.add_option('--clean', default=False, dest='clean', action='store_true',
                    help='Clean all previous state')
  parser.add_option('--no_delta', action='store_false', default=True,
                    dest='delta',
                    help='Disable using delta updates.')
  parser.add_option('--no_graphics', action='store_true',
                    help='Disable graphics for the vm test.')
  parser.add_option('-j', '--jobs', default=8, type=int,
                     help='Number of simultaneous jobs')
  parser.add_option('--public_key', default=None,
                     help='Public key to use on images and updates.')
  parser.add_option('--private_key', default=None,
                     help='Private key to use on images and updates.')
  parser.add_option('-q', '--quick_test', default=False, action='store_true',
                    help='Use a basic test to verify image.')
  parser.add_option('-m', '--remote',
                    help='Remote address for real test.')
  parser.add_option('-t', '--target_image',
                    help='path to the target image.')
  parser.add_option('--test_results_root', default=None,
                    help='Root directory to store test results.  Should '
                         'be defined relative to chroot root.')
  parser.add_option('--test_prefix', default='test',
                    help='Only runs tests with specific prefix i.e. '
                         'testFullUpdateWipeStateful.')
  parser.add_option('-p', '--type', default='vm',
                    help='type of test to run: [vm, real]. Default: vm.')
  parser.add_option('--verbose', default=True, action='store_true',
                    help='Print out rather than capture output as much as '
                         'possible.')
  (options, leftover_args) = parser.parse_args()

  if leftover_args: parser.error('Found unsupported flags: %s' % leftover_args)

  assert options.target_image and os.path.exists(options.target_image), \
    'Target image path does not exist'
  if not options.base_image:
    cros_lib.Info('Base image not specified.  Using target as base image.')
    options.base_image = options.target_image

  # Sanity checks on keys and insert them onto the image.  The caches must be
  # cleaned so we know that the vm images and payloads match the possibly new
  # key.
  if options.private_key or options.public_key:
    error_msg = ('Could not find %s key.  Both private and public keys must be '
                 'specified if either is specified.')
    assert options.private_key and os.path.exists(options.private_key), \
        error_msg % 'private'
    assert options.public_key and os.path.exists(options.public_key), \
        error_msg % 'public'
    _InsertPublicKeyIntoImage(options.target_image, options.public_key)
    if options.target_image != options.base_image:
      _InsertPublicKeyIntoImage(options.base_image, options.public_key)
    options.clean = True

  # Clean up previous work if requested.
  if options.clean: _CleanPreviousWork(options)

  # Generate cache of updates to use during test harness.
  update_cache = _PregenerateUpdates(options)
  au_worker.AUWorker.SetUpdateCache(update_cache)

  my_server = dev_server_wrapper.DevServerWrapper()
  my_server.start()
  try:
    if options.type == 'vm':
      _RunTestsInParallel(options)
    else:
      # TODO(sosa) - Take in a machine pool for a real test.
      # Can't run in parallel with only one remote device.
      test_suite = _PrepareTestSuite(options)
      test_result = unittest.TextTestRunner(verbosity=2).run(test_suite)
      if not test_result.wasSuccessful(): cros_lib.Die('Test harness failed.')
  finally:
    my_server.Stop()


if __name__ == '__main__':
  main()
