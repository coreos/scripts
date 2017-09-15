# Copyright (c) 2017 The Container Linux by CoreOS Authors. All rights
# reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# torcx_manifest.sh contains helper functions for creating, editing, and
# reading torcx manifest files.

# create_empty creates an empty torcx manfiest at the given path.
function torcx_manifest::create_empty() {
  local path="${1}"
  jq '.' > "${path}" <<EOF
{
  "kind": "torcx-package-list-v0",
  "value": {
    "packages": []
  }
}
EOF
}

# add_pkg adds a new version of a package to the torcx manifest specified by
# path.
# That manifest will be edited to include this version, with the associated
# package of the given name being created as well if necessary.
function torcx_manifest::add_pkg() {
  path="${1}"; shift
  name="${1}"; shift
  version="${1}"; shift
  pkg_hash="${1}"; shift
  cas_digest="${1}"; shift
  source_package="${1}"; shift
  update_default="${1}"; shift

  local manifest=$(cat "${path}")
  local pkg_version_obj=$(jq '.' <<EOF
{
  "version": "${version}",
  "hash": "${pkg_hash}",
  "casDigest": "${cas_digest}",
  "sourcePackage": "${source_package}",
  "locations": []
}
EOF
)

  for location in "${@}"; do
    if [[ "${location}" == /* ]]; then
      # filepath
      pkg_version_obj=$(jq ".locations |= . + [{\"path\": \"${location}\"}]" <(echo "${pkg_version_obj}"))
    else
      # url
      pkg_version_obj=$(jq ".locations |= . + [{\"url\": \"${location}\"}]" <(echo "${pkg_version_obj}"))
    fi
  done


  local existing_pkg="$(echo "${manifest}" | jq ".value.packages[] | select(.name == \"${name}\")")"

  # If there isn't yet a package in the manifest for $name, initialize it to an empty one.
  if [[ "${existing_pkg}" == "" ]]; then
    pkg_json=$(cat <<EOF
    {
      "name": "${name}",
      "versions": []
    }
EOF
)
    manifest="$(echo "${manifest}" | jq ".value.packages |= . + [${pkg_json}]")"
  fi

  if [[ "${update_default}" == "true" ]]; then
    manifest="$(echo "${manifest}" | jq "(.value.packages[] | select(.name = \"${name}\") | .defaultVersion) |= \"${version}\"")"
  fi

  # append this specific package version to the manifest
  manifest="$(echo "${manifest}" | jq "(.value.packages[] | select(.name = \"${name}\") | .versions) |= . + [${pkg_version_obj}]")"

  echo "${manifest}" | jq '.' > "${path}"
}

# get_pkg_names returns the list of packages in a given manifest. Each package
# may have one or more versions associated with it.
#
# Example:
#     pkg_name_arr=($(torcx_manifest::get_pkg_names "torcx_manifest.json"))
function torcx_manifest::get_pkg_names() {
  local file="${1}"
  jq -r '.value.packages[].name' < "${file}"
}

# local_store_path returns the in-container-linux store path a given package +
# version combination should exist at. It returns the empty string if the
# package shouldn't exist on disk.
function torcx_manifest::local_store_path() {
  local file="${1}"
  local name="${2}"
  local version="${3}"
  jq -r ".value.packages[] | select(.name == \"${name}\") | .versions[] | select(.version == \"${version}\") | .locations[] | select(.path).path" < "${file}"
}

# get_digest returns the cas digest for a given package version
function torcx_manifest::get_digest() {
  local file="${1}"
  local name="${2}"
  local version="${3}"
  jq -r ".value.packages[] | select(.name == \"${name}\") | .versions[] | select(.version == \"${version}\") | .casDigest" < "${file}"
}

# get_digests returns the list of digests for a given package. 
function torcx_manifest::get_digests() {
  local file="${1}"
  local name="${2}"
  jq -r ".value.packages[] | select(.name == \"${name}\").versions[].casDigest" < "${file}"
}

# get_versions returns the list of versions for a given package. 
function torcx_manifest::get_versions() {
  local file="${1}"
  local name="${2}"
  jq -r ".value.packages[] | select(.name == \"${name}\").versions[].version" < "${file}"
}

# default_version returns the default version for a given package, or an empty string if there isn't one.
function torcx_manifest::default_version() {
  local file="${1}"
  local name="${2}"
  jq -r ".value.packages[] | select(.name == \"${name}\").defaultVersion" < "${file}"
}

# sources_on_disk returns the list of source packages of all torcx images installed on disk
function torcx_manifest::sources_on_disk() {
  local file="${1}"
  jq -r ".value.packages[].versions[] | select(.locations[].path).sourcePackage" < "${file}"
}
