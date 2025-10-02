#!/bin/bash -e
#
# Repackaging Git for Windows and bundling Git LFS from upstream.
#

set -eu -o pipefail

if [[ -z "${DESTINATION}" ]]; then
  echo "Required environment variable DESTINATION was not set"
  exit 1
fi

case "$TARGET_ARCH" in
  "x64")
    DEPENDENCY_ARCH="amd64"
    MINGW_DIR="mingw64";;
  "arm64")
    DEPENDENCY_ARCH="arm64"
    MINGW_DIR="clangarm64";;
  *)
    echo "Unsupported architecture: $TARGET_ARCH"
    exit 1 ;;
esac

GIT_LFS_VERSION=$(jq --raw-output ".[\"git-lfs\"].version[1:]" dependencies.json)
GIT_LFS_CHECKSUM="$(jq --raw-output ".\"git-lfs\".files[] | select(.arch == \"$DEPENDENCY_ARCH\" and .platform == \"windows\") | .checksum" dependencies.json)"
GIT_LFS_FILENAME="$(jq --raw-output ".\"git-lfs\".files[] | select(.arch == \"$DEPENDENCY_ARCH\" and .platform == \"windows\") | .name" dependencies.json)"
GIT_FOR_WINDOWS_URL=$(jq --raw-output ".git.packages[] | select(.arch == \"$DEPENDENCY_ARCH\" and .platform == \"windows\") | .url" dependencies.json)
GIT_FOR_WINDOWS_FILENAME="$(jq --raw-output ".git.packages[] | select(.arch == \"$DEPENDENCY_ARCH\" and .platform == \"windows\") | .filename" dependencies.json)"
GIT_FOR_WINDOWS_CHECKSUM=$(jq --raw-output ".git.packages[] | select(.arch == \"$DEPENDENCY_ARCH\" and .platform == \"windows\") | .checksum" dependencies.json)

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=script/compute-checksum.sh
source "$CURRENT_DIR/compute-checksum.sh"

mkdir -p "$DESTINATION"

echo "-- Downloading PortableGit from $GIT_FOR_WINDOWS_URL"
curl -sL -o "$GIT_FOR_WINDOWS_FILENAME" "$GIT_FOR_WINDOWS_URL"
COMPUTED_SHA256=$(compute_checksum "$GIT_FOR_WINDOWS_FILENAME")
if [ "$COMPUTED_SHA256" = "$GIT_FOR_WINDOWS_CHECKSUM" ]; then
  echo "PortableGit: checksums match"
  7z.exe x -o"$DESTINATION" "$GIT_FOR_WINDOWS_FILENAME"
else
  echo "PortableGit: expected checksum $GIT_FOR_WINDOWS_CHECKSUM but got $COMPUTED_SHA256"
  echo "aborting..."
  exit 1
fi

unset COMPUTED_SHA256

GAWK_URL="https://mirror.msys2.org/msys/x86_64/gawk-5.3.1-1-x86_64.pkg.tar.zst"
GAWK_FILENAME="gawk-5.3.1-1-x86_64.pkg.tar.zst"
GAWK_CHECKSUM="9ce65f18c696723278031d05d978b0eb0cb9ee2db2d1d8c2bd5603d050b09096"

echo "-- Upgrading GAWK"
curl -sL -o "$GAWK_FILENAME" "$GAWK_URL"
COMPUTED_SHA256=$(compute_checksum "$GAWK_FILENAME")
if [ "$COMPUTED_SHA256" = "$GAWK_CHECKSUM" ]; then
  echo "GAWK: checksums match"
  tar -xvf "$GAWK_FILENAME" -C "$DESTINATION" --exclude="*.BUILDINFO" --exclude="*.MTREE" --exclude="*.PKGINFO"
  rm "$GAWK_FILENAME"
else
  echo "GAWK: expected checksum $GIT_FOR_WINDOWS_CHECKSUM but got $COMPUTED_SHA256"
  echo "aborting..."
  exit 1
fi

echo "-- Deleting Unneccessary Files"
cd "$DESTINATION"
tr -d '\r' < "$CURRENT_DIR/windows-blacklist.txt" | xargs -d '\n' rm -rf

if [[ "$GIT_LFS_VERSION" ]]; then
  # download Git LFS, verify its the right contents, and unpack it
  echo "-- Bundling Git LFS"
  GIT_LFS_FILE=git-lfs.zip
  GIT_LFS_URL="https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/${GIT_LFS_FILENAME}"
  echo "-- Downloading from $GIT_LFS_URL"
  curl -sL -o $GIT_LFS_FILE "$GIT_LFS_URL"
  COMPUTED_SHA256=$(compute_checksum $GIT_LFS_FILE)
  if [ "$COMPUTED_SHA256" = "$GIT_LFS_CHECKSUM" ]; then
    echo "Git LFS: checksums match"
    SUBFOLDER="$DESTINATION/$MINGW_DIR/libexec/git-core"
    unzip -j $GIT_LFS_FILE -x '*.md' -d "$SUBFOLDER"

    if [[ ! -f "$SUBFOLDER/git-lfs.exe" ]]; then
      echo "After extracting Git LFS the file was not found under /mingw64/libexec/git-core/"
      echo "aborting..."
      exit 1
    fi
  else
    echo "Git LFS: expected checksum $GIT_LFS_CHECKSUM and got $COMPUTED_SHA256"
    echo "aborting..."
    exit 1
  fi
else
  echo "-- Skipped bundling Git LFS (set GIT_LFS_VERSION to include it in the bundle)"
fi

if [[ -f "$DESTINATION/etc/gitconfig" ]]; then
  SYSTEM_CONFIG="$DESTINATION/etc/gitconfig"

  if [[ -f "$DESTINATION/$MINGW_DIR/etc/gitconfig" ]]; then
    echo "System level git config file found in both locations"
    echo "aborting..."
    exit 1
  fi
elif [[ -f "$DESTINATION/$MINGW_DIR/etc/gitconfig" ]]; then
  SYSTEM_CONFIG="$DESTINATION/$MINGW_DIR/etc/gitconfig"
else
  echo "Could not locate system git config file"
  echo "aborting..."
  exit 1
fi

set +eu

echo "-- Setting some system configuration values"
git config --file "$SYSTEM_CONFIG" core.symlinks "false"
git config --file "$SYSTEM_CONFIG" core.autocrlf "true"
git config --file "$SYSTEM_CONFIG" core.fscache "true"
git config --file "$SYSTEM_CONFIG" http.sslBackend "schannel"
git config --file "$SYSTEM_CONFIG" credential.helper "manager"

# See https://github.com/desktop/desktop/issues/4817#issuecomment-393241303
# Even though it's not set openssl will auto-discover the one we ship because
# it sits in the right location already. So users manually switching
# http.sslBackend to openssl will still pick it up.
git config --file "$SYSTEM_CONFIG" --unset http.sslCAInfo

# Git for Windows 2.18.1 will support controlling how curl uses any certificate
# bundle - rather than just loading the bundle if http.useSSLCAInfo is set
# For the moment we want to favour using the OS certificate store unless the
# user has overriden this in their global configuration.
#
# details: https://github.com/dscho/git/blob/6152657e1a97c478df97d633c47469043b397519/Documentation/config.txt#L2135
git config --file "$SYSTEM_CONFIG" http.schannelUseSSLCAInfo "false"

set -eu -o pipefail

# removing global gitattributes file
echo "-- Removing system level gitattributes which handles certain file extensions"

if [[ -f "$DESTINATION/etc/gitattributes" ]]; then
  rm "$DESTINATION/etc/gitattributes"

  if [[ -f "$DESTINATION/$MINGW_DIR/etc/gitattributes" ]]; then
    echo "System level git attributes file found in both locations"
    echo "aborting..."
    exit 1
  fi
elif [[ -f "$DESTINATION/$MINGW_DIR/etc/gitattributes" ]]; then
  rm "$DESTINATION/$MINGW_DIR/etc/gitattributes"
fi

set +eu
