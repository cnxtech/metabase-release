#!/usr/bin/env bash

# The expectation is that this script will be run in a directory
# containing a 'certs' subdirectory with the
# keystore file (named metabase_keystore.jks) and
# The mac app pem signing key (named "key.pem")
# If not, you will be prompted


set -euo pipefail


if [ $# -lt 1 ]; then
    echo "usage: $0 X.Y.Z [BRANCH]"
    exit 1
fi
VERSION=$1

if [ $# -lt 2 ]; then
    BRANCH="release-$VERSION"
else
    BRANCH=$2
fi

root_dir=`pwd`

# check that docker is running
docker ps > /dev/null

# ensure DockerHub credentials are configured
if [ -z ${DOCKERHUB_EMAIL+x} ] || [ -z ${DOCKERHUB_USERNAME+x} ] || [ -z ${DOCKERHUB_PASSWORD+x} ]; then
    echo "Ensure DOCKERHUB_EMAIL, DOCKERHUB_USERNAME, and DOCKERHUB_PASSWORD are set.";
    exit 1
fi

# ensure AWS is configured for the Beanstalk build
if [ -z ${AWS_DEFAULT_PROFILE+x} ]; then
    echo "Using default AWS_DEFAULT_PROFILE.";
    AWS_DEFAULT_PROFILE=default
fi

# confirm the version and branch
echo "Releasing v$VERSION from branch $BRANCH. Press enter to continue or ctrl-C to abort."
read

# ensure the main repo is cloned
if ! [ -d "metabase" ]; then
    git clone git@github.com:metabase/metabase.git
fi

echo "fetching"
cd "$root_dir"/metabase
git fetch

echo "checkout the correct branch : $BRANCH from origin/$BRANCH"
git checkout "$BRANCH"

echo "ensure the version is correct"
sed -i '' s/^VERSION.*/VERSION=\"v$VERSION\"/ bin/version
git commit -m "v$VERSION" bin/version || true

echo "delete old tags"
git push --delete origin "v$VERSION" || true
git tag --delete "v$VERSION" || true

echo "taging it"
git tag -a "v$VERSION" -m "v$VERSION"
git push --follow-tags -u origin "$BRANCH"

echo "build it"
bin/build

echo "uploading to s3"
aws s3 cp "target/uberjar/metabase.jar" "s3://downloads.metabase.com/v$VERSION/metabase.jar"

echo "build docker image + publish"
bin/docker/build_image.sh release "v$VERSION" --publish

echo "create elastic beanstalk artifacts"
bin/aws-eb-docker/release-eb-version.sh "v$VERSION"

cd "$root_dir"

echo "pulling down metabase-buildpack"
if ! [ -d "metabase-buildpack" ]; then
    echo "cant find ... cloning"
    git clone git@github.com:metabase/metabase-buildpack.git
fi

echo "pulling"
cd "$root_dir"/metabase-buildpack
git checkout master
git pull

echo "release heroku artifacts"
echo "$VERSION" > bin/version
git add .
git commit -m "Deploy v$VERSION"
git tag "$VERSION"
git push
git push --tags origin master

echo "Build completed successfully!"

echo "Calculating SHA-256 sum:"
cd "$root_dir"
shasum -a 256 ./metabase/target/uberjar/metabase.jar
