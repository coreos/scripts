#!/bin/sh -e

if [ -z $1 ]; then
	echo "Pass Jenkins URL"
	exit 1
fi

JENKINS_URL=$1

for PLUGIN in git github rebuild parameterized-trigger copyartifact ssh-agent job-restrictions credentials-binding tap matrix-project; do
	echo "Installing $PLUGIN..."
	curl --silent --header "Content-Type: application/xml" -XPOST "$JENKINS_URL/pluginManager/installNecessaryPlugins" --data "<install plugin=\"$PLUGIN@current\" />" >/dev/null
done

for JOB in $(find jobs/ -mindepth 1 -maxdepth 1 -type d); do
	J=$(basename $JOB)
	echo "Creating job $J..."
	curl --silent --header "Content-Type: application/xml" -XPOST "$JENKINS_URL/createItem?name=$J" --data-binary "@$JOB/config.xml" >/dev/null
done

curl -XPOST $JENKINS_URL/updateCenter/safeRestart

echo "Visit $JENKINS_URL/updateCenter and wait for Jenkins to restart."

