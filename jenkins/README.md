The scripts in this directory are run from [OS Jenkins jobs][jenkins-os].  By
storing the Jenkins scripts in this repository, they are more tightly coupled
to the release branch of the SDK scripts that they require.  The Jenkins jobs
are responsible for setting up the environment and securely initializing an SDK
in the workspace before running these scripts.

The special files named `formats-${BOARD}.txt` are space-separated lists of VM
image formats that should be built for releases on this branch; i.e. the script
`vm.sh` is run for each item in the list.

[jenkins-os]: https://github.com/coreos/jenkins-os
