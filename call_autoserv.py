#!/usr/bin/python

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Script to run client or server tests on a live remote image.

This script can be used to save results of each test run in timestamped
unique results directory.

"""

import datetime
import glob
import logging
import os
import sys
import time
from optparse import OptionParser

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
conlog = logging.StreamHandler()
conlog.setLevel(logging.INFO)
formatter = logging.Formatter("%(asctime)s %(levelname)s | %(message)s")
conlog.setFormatter(formatter)
logger.addHandler(conlog)

def ConnectRemoteMachine(machine_ip):
  os.system("eval `ssh-agent -s`")
  os.system("ssh-add testing_rsa")
  username = os.environ['USER']

  # Removing the machine IP entry from known hosts to avoid identity clash.
  logger.info("Removing machine IP entry from known hosts to avoid identity"
              " clash.")
  host_list = open("/home/%s/.ssh/known_hosts" % username, "r").readlines()
  index = 0
  for host in host_list:
    if machine_ip in host:
      del host_list[index]
      break
    index += 1

  open("/home/%s/.ssh/known_hosts" % username, "w").writelines(host_list)

  # Starting ssh connection to remote test machine.
  logger.info("Starting ssh connection to remote test machine.")
  os.system("ssh root@%s true; echo $? > ssh_result_file" % machine_ip)
  ssh_result = open("ssh_result_file", "r").read()
  logger.info("Status of ssh connection to remote machine : %s" % ssh_result)

  if ssh_result.strip() != '0':
    logger.error("Ssh connection to remote test machine FAILED. Exiting the"
                 " test.")
    sys.exit()

def TestSearch(suite_path, test_name):
  test_path = ""
  filenames = glob.glob(os.path.join(suite_path, test_name))
  for filename in filenames:
    if filename == ("%s/%s" % (suite_path, test_name)):
      test_path = filename
      break
  return test_path

def TriggerTest(test_name, machine_ip):
  # Creating unique time stamped result folder name.
  current_time = datetime.datetime.now()
  result_name = "results." + test_name + current_time.strftime("_%d-%m-%y"
                                                               "_%H:%M")

  # Setting the test path location based on the test_name.
  suite_path = "./autotest/client/site_tests/suite_HWQual"
  test_path = TestSearch(suite_path, "control.%s" % test_name)

  # Looking for test_name under client/site_tests if not under suite_HWQual.
  if test_path == "":
    suite_path = ("./autotest/client/site_tests/%s" % test_name)
    test_path = TestSearch(suite_path, "control")

  # Looking for test_name under server/site_tests if not present under client.
  if test_path == "":
    suite_path = ("./autotest/server/site_tests/%s" % test_name)
    test_path = TestSearch(suite_path, "control")
    # Looking for test_name under server/site_tests/suites.
    if test_path == "":
      suite_path = "./autotest/server/site_tests/suites"
      test_path = TestSearch(suite_path, "control.%s" % test_name)
    # Setting command for server tests.
    run_command = ("./autotest/server/autoserv -r ./autotest/%s -m %s"
                   " -s %s" % (result_name, machine_ip, test_path))
  else:
    run_command = ("./autotest/server/autoserv -r ./autotest/%s -m %s "
                   "-c %s" % (result_name, machine_ip, test_path))

  if test_path == "":
    logger.error("Test not found under client or server directories! Check the "
                 "name of test and do not prefix 'control.' to test name.")
    sys.exit()

  # Making the call to HWQual test.
  logger.info("Starting the HWQual test : %s" % test_path)
  os.system(run_command)

  # Displaying results on test completion.
  test_result = os.system("./generate_test_report ./autotest/%s" % result_name)

  result_path = ("./autotest/%s" % result_name)
  if test_result != 0:
    # Grabbing the results directory as test failed & return value nonzero.
    log_name = ("%s.tar.bz2" % result_path)
    os.system("tar cjf %s %s" % (log_name, result_path))
    logger.info("Logs for the failed test at : %s" % log_name)

  logger.info("Results of test run at : %s" % result_path)

def main(argv):
  # Checking the arguments for help, machine ip and test name.
  parser = OptionParser(usage="USAGE : ./%prog [options]")

  parser.add_option("--ip", dest="dut_ip",
                    help="accepts IP address of device under test <DUT>.")
  parser.add_option("--test", dest="test_name",
                    help="accepts HWQual test name without prefix 'control.'")

  (options, args) = parser.parse_args()

  # Checking for presence of both ip and test parameters.
  if (options.dut_ip == None) or (options.test_name == None):
    parser.error("Argument missing! Both --ip and --test arguments required.")

  # Checking for blank values of both ip and test parameters.
  arg_ip, arg_testname = options.dut_ip, options.test_name
  if (arg_ip == "") or (arg_testname == ""):
    parser.error("Blank values are not accepted for arguments.")

  logger.info("HWQual test to trigger : %s" % arg_testname)
  logger.info("Remote test machine IP : %s" % arg_ip)

  # Setting up ssh connection to remote machine.
  ConnectRemoteMachine(arg_ip)

  # Triggerring the HWQual test and result handling.
  TriggerTest(arg_testname, arg_ip)


if __name__ == '__main__':
  main(sys.argv)
